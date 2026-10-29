//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// fakeAppIndex builds an index over a temporary /Applications holding the
// given bundles, with Info.plist values served from apps instead of plutil.
func fakeAppIndex(t *testing.T, home string, apps map[string]installedApp) *explainAppIndex {
	t.Helper()
	root := t.TempDir()
	for bundle := range apps {
		if err := os.MkdirAll(filepath.Join(root, bundle, "Contents"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return &explainAppIndex{
		home:  home,
		roots: []string{root, filepath.Join(root, "missing-root")},
		readKey: func(_ context.Context, plistPath, key string) (string, error) {
			app := apps[filepath.Base(filepath.Dir(filepath.Dir(plistPath)))]
			value := map[string]string{"CFBundleIdentifier": app.BundleID, "CFBundleName": app.BundleName}[key]
			if value == "" {
				return "", errors.New("No value at that key path")
			}
			return value, nil
		},
	}
}

func TestLibraryOwnerToken(t *testing.T) {
	home := "/Users/me"
	tests := []struct {
		path string
		want string
		ok   bool
	}{
		{path: "/Users/me/Library/Containers/com.docker.docker", want: "com.docker.docker", ok: true},
		{path: "/Users/me/Library/Containers/com.docker.docker/Data/vms", want: "com.docker.docker", ok: true},
		{path: "/Users/me/Library/Application Support/Code", want: "Code", ok: true},
		{path: "/Users/me/Library/Preferences/com.foo.bar.plist", want: "com.foo.bar", ok: true},
		{path: "/Users/me/Library/Saved Application State/com.foo.bar.savedState", want: "com.foo.bar", ok: true},
		{path: "/Users/me/Library/Cookies/com.foo.bar.binarycookies", want: "com.foo.bar", ok: true},
		{path: "/Users/me/Library/Group Containers/group.com.foo.shared", want: "com.foo.shared", ok: true},
		{path: "/Users/me/Library/Group Containers/UBF8T346G9.com.microsoft.teams", want: "com.microsoft.teams", ok: true},
		{path: "/Library/Application Support/com.bar.helper", want: "com.bar.helper", ok: true},
		{path: "/Users/me/Library/Caches", ok: false},
		{path: "/Users/me/Library/Developer/CoreSimulator", ok: false},
		{path: "/Users/me/Documents/Containers/com.foo", ok: false},
		{path: "/Users/meow/Library/Caches/com.foo", ok: false},
	}
	for _, tt := range tests {
		got, ok := libraryOwnerToken(tt.path, home)
		if ok != tt.ok || got != tt.want {
			t.Fatalf("libraryOwnerToken(%q) = %q, %v; want %q, %v", tt.path, got, ok, tt.want, tt.ok)
		}
	}
}

func TestExplainAppIndexMatch(t *testing.T) {
	index := fakeAppIndex(t, "/Users/me", map[string]installedApp{
		"Docker.app":             {BundleID: "com.docker.docker"},
		"Visual Studio Code.app": {BundleID: "com.microsoft.VSCode", BundleName: "Code"},
		"Google Chrome.app":      {BundleID: "com.google.Chrome"},
	})
	index.load(context.Background())

	tests := []struct {
		token string
		want  string
	}{
		{token: "com.docker.docker", want: "Docker"},
		{token: "COM.DOCKER.DOCKER", want: "Docker"},
		{token: "com.docker.docker.helper", want: "Docker"},
		{token: "com.microsoft.vscode.ShipIt", want: "Visual Studio Code"},
		{token: "Code", want: "Visual Studio Code"},
		{token: "visual studio code", want: "Visual Studio Code"},
		{token: "com.google", want: ""},
		{token: "com.google.drivefs", want: ""},
		{token: "Slack", want: ""},
	}
	for _, tt := range tests {
		app, ok := index.match(tt.token)
		if got := map[bool]string{true: app.Name}[ok]; got != tt.want {
			t.Fatalf("match(%q) = %q, want %q", tt.token, got, tt.want)
		}
	}
}

func TestExplainAppIndexOwnerOf(t *testing.T) {
	home := "/Users/me"
	index := fakeAppIndex(t, home, map[string]installedApp{"Docker.app": {BundleID: "com.docker.docker"}})
	ctx := context.Background()

	if owner := index.ownerOf(ctx, "/Users/me/Library/Containers/com.docker.docker"); owner.kind != explainOwnerInstalled {
		t.Fatalf("installed owner = %+v", owner)
	}
	if owner := index.ownerOf(ctx, "/Users/me/Library/Containers/com.tinyspeck.slackmacgap"); owner.kind != explainOwnerMissing || owner.token != "com.tinyspeck.slackmacgap" {
		t.Fatalf("missing owner = %+v", owner)
	}
	// AddressBook is the Contacts app's data: a plain name with no matching app
	// proves nothing, so it must not be reported as missing.
	if owner := index.ownerOf(ctx, "/Users/me/Library/Application Support/AddressBook"); owner.kind != explainOwnerUnknown {
		t.Fatalf("plain folder name = %+v, want no claim", owner)
	}
	if owner := index.ownerOf(ctx, "/Users/me/Library/Application Support/com.apple.akd"); owner.kind != explainOwnerApple {
		t.Fatalf("apple owner = %+v", owner)
	}
	if owner := index.ownerOf(ctx, "/Users/me/Documents/report.pdf"); owner.kind != explainOwnerUnknown {
		t.Fatalf("path outside Library = %+v", owner)
	}
}

func TestExplainAppIndexNeverClaimsMissingWhenIncomplete(t *testing.T) {
	index := fakeAppIndex(t, "/Users/me", map[string]installedApp{"Docker.app": {BundleID: "com.docker.docker"}})
	locked := filepath.Join(t.TempDir(), "locked")
	if err := os.Mkdir(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	index.roots = append(index.roots, locked)

	if owner := index.ownerOf(context.Background(), "/Users/me/Library/Caches/com.vanished.app"); owner.kind != explainOwnerUnknown {
		t.Fatalf("owner = %+v: an unreadable app root must not prove an app is missing", owner)
	}
	if owner := index.ownerOf(context.Background(), "/Users/me/Library/Caches/com.docker.docker"); owner.kind != explainOwnerInstalled {
		t.Fatalf("a found app is still reported: %+v", owner)
	}
}

func TestExplainAppIndexLoadsOnceAndOnlyWhenNeeded(t *testing.T) {
	var reads atomic.Int64
	index := fakeAppIndex(t, "/Users/me", map[string]installedApp{"A.app": {BundleID: "com.a.app"}, "B.app": {BundleID: "com.b.app"}})
	readKey := index.readKey
	index.readKey = func(ctx context.Context, plistPath, key string) (string, error) {
		reads.Add(1)
		return readKey(ctx, plistPath, key)
	}

	index.ownerOf(context.Background(), "/tmp/not-in-library")
	if reads.Load() != 0 {
		t.Fatal("a path outside Library must not build the app inventory")
	}
	for range 3 {
		index.ownerOf(context.Background(), "/Users/me/Library/Caches/com.a.app")
	}
	if got := reads.Load(); got != 4 {
		t.Fatalf("plist reads = %d, want 2 keys x 2 apps once", got)
	}
	if !index.complete || len(index.apps) != 2 {
		t.Fatalf("index = %+v", index.apps)
	}
}

func TestReadPlistKeyReadsRealInfoPlist(t *testing.T) {
	const notes = "/System/Applications/Notes.app/Contents/Info.plist"
	if _, err := os.Stat(notes); err != nil {
		t.Skipf("no Notes.app on this machine: %v", err)
	}
	id, err := readPlistKey(context.Background(), notes, "CFBundleIdentifier")
	if err != nil || !strings.EqualFold(id, "com.apple.Notes") {
		t.Fatalf("readPlistKey() = %q, %v", id, err)
	}
	if _, err := readPlistKey(context.Background(), notes, "NoSuchKeyForMole"); err == nil {
		t.Fatal("a missing key must be an error")
	}
}

func TestExpandHomeDir(t *testing.T) {
	if got, ok := expandHomeDir("~/Applications", "/Users/me"); !ok || got != "/Users/me/Applications" {
		t.Fatalf("expandHomeDir(~) = %q, %v", got, ok)
	}
	if got, ok := expandHomeDir("/Applications", ""); !ok || got != "/Applications" {
		t.Fatalf("expandHomeDir(abs) = %q, %v", got, ok)
	}
	if _, ok := expandHomeDir("~/Applications", ""); ok {
		t.Fatal("a home-relative path needs a home directory")
	}
}
