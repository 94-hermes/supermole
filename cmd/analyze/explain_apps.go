//go:build darwin

package main

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

const (
	explainAppIndexWorkers = 8
	explainAppIndexTimeout = 5 * time.Second
	// A shared prefix shorter than this names a vendor (com.google), not an app.
	explainMinBundleIDLabels = 3
	plutilBinary             = "/usr/bin/plutil"
)

// The app roots of lib/core/bundle_resolver.sh, minus the Caskroom and input
// method folders: casks link their apps into /Applications. Spotlight is not
// used, for the reasons given there.
var explainAppRoots = []string{
	"/Applications",
	"/Applications/Setapp",
	"/Applications/Utilities",
	"/System/Applications",
	"/System/Applications/Utilities",
	"~/Applications",
	"~/Library/Application Support/Setapp/Applications",
}

// Library folders whose direct children are named after the app that owns them.
var explainOwnedLibraryDirs = []string{
	"Application Support",
	"Caches",
	"Containers",
	"Group Containers",
	"Preferences",
	"Saved Application State",
	"Logs",
	"HTTPStorages",
	"WebKit",
	"Cookies",
	"Application Scripts",
	"LaunchAgents",
}

// Suffixes macOS appends to an app identifier in those folders.
var explainOwnerTokenSuffixes = []string{".plist", ".savedState", ".binarycookies"}

var (
	teamIDPrefixPattern = regexp.MustCompile(`^[A-Z0-9]{10}\.`)
	bundleIDPattern     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$`)
)

type installedApp struct {
	Name       string // bundle file name without .app, as Finder lists it
	BundleName string
	BundleID   string
}

type explainOwnerKind int

const (
	explainOwnerUnknown   explainOwnerKind = iota // not in an app-keyed folder, or the inventory is incomplete
	explainOwnerInstalled                         // an installed app matches
	explainOwnerMissing                           // no installed app carries the identifier
	explainOwnerApple                             // an Apple identifier with no matching app
)

type explainOwner struct {
	kind  explainOwnerKind
	token string // the identifier or name taken from the path
	app   installedApp
}

type plistKeyReader func(ctx context.Context, plistPath, key string) (string, error)

// explainAppIndex lists installed apps once per analyzer run, on the first
// request that needs it.
type explainAppIndex struct {
	once     sync.Once
	home     string
	roots    []string
	readKey  plistKeyReader
	apps     []installedApp
	complete bool
}

func newExplainAppIndex() *explainAppIndex {
	// Without a home directory only the system roots are listed; the index
	// then reports itself incomplete and claims no app is missing.
	home, homeErr := os.UserHomeDir()
	index := &explainAppIndex{home: home, roots: explainAppRoots, readKey: readPlistKey}
	if homeErr != nil {
		index.home = ""
	}
	return index
}

func readPlistKey(ctx context.Context, plistPath, key string) (string, error) {
	output, err := exec.CommandContext(ctx, plutilBinary, "-extract", key, "raw", "-o", "-", plistPath).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

// ownerOf says which installed app a Library path seems to belong to. It is a
// hint for the model, never a basis for deleting anything.
func (idx *explainAppIndex) ownerOf(ctx context.Context, path string) explainOwner {
	token, ok := libraryOwnerToken(path, idx.home)
	if !ok {
		return explainOwner{}
	}
	idx.load(ctx)
	if app, found := idx.match(token); found {
		return explainOwner{kind: explainOwnerInstalled, token: token, app: app}
	}
	if strings.HasPrefix(strings.ToLower(token), "com.apple.") {
		return explainOwner{kind: explainOwnerApple, token: token}
	}
	// Only an identifier proves absence. Plain folder names are often macOS
	// services (AddressBook holds the Contacts app's data) or vendors, so a
	// name with no matching app says nothing about whether it is still used.
	if !idx.complete || !bundleIDPattern.MatchString(token) {
		return explainOwner{}
	}
	return explainOwner{kind: explainOwnerMissing, token: token}
}

// libraryOwnerToken takes the app identifier or name from a path at or below
// an app-keyed folder of ~/Library or /Library, such as the
// "com.docker.docker" in ~/Library/Containers/com.docker.docker/Data.
func libraryOwnerToken(path, home string) (string, bool) {
	libraries := []string{"/Library"}
	if home != "" {
		libraries = append(libraries, filepath.Join(home, "Library"))
	}
	for _, library := range libraries {
		rest, ok := strings.CutPrefix(path, library+"/")
		if !ok {
			continue
		}
		parts := strings.Split(rest, "/")
		if len(parts) < 2 || parts[1] == "" || !slices.Contains(explainOwnedLibraryDirs, parts[0]) {
			return "", false
		}
		return normalizeOwnerToken(parts[1]), true
	}
	return "", false
}

func normalizeOwnerToken(name string) string {
	for _, suffix := range explainOwnerTokenSuffixes {
		if trimmed, ok := strings.CutSuffix(name, suffix); ok {
			name = trimmed
			break
		}
	}
	name = strings.TrimPrefix(name, "group.")
	return teamIDPrefixPattern.ReplaceAllString(name, "")
}

func (idx *explainAppIndex) match(token string) (installedApp, bool) {
	if bundleIDPattern.MatchString(token) {
		for _, app := range idx.apps {
			if strings.EqualFold(app.BundleID, token) {
				return app, true
			}
		}
		for _, app := range idx.apps {
			if app.BundleID != "" && relatedBundleIDs(strings.ToLower(app.BundleID), strings.ToLower(token)) {
				return app, true
			}
		}
		return installedApp{}, false
	}
	for _, app := range idx.apps {
		if strings.EqualFold(app.Name, token) || (app.BundleName != "" && strings.EqualFold(app.BundleName, token)) {
			return app, true
		}
	}
	return installedApp{}, false
}

// relatedBundleIDs reports whether one lowercase identifier extends the other
// at a dot boundary, as a helper (com.docker.docker.helper) extends its app,
// while the shorter one is still specific enough to name a single app.
func relatedBundleIDs(a, b string) bool {
	shorter, longer := a, b
	if len(shorter) > len(longer) {
		shorter, longer = longer, shorter
	}
	if strings.Count(shorter, ".")+1 < explainMinBundleIDLabels {
		return false
	}
	return strings.HasPrefix(longer, shorter+".")
}

func (idx *explainAppIndex) load(ctx context.Context) {
	idx.once.Do(func() {
		ctx, cancel := context.WithTimeout(ctx, explainAppIndexTimeout)
		defer cancel()

		bundles, listed := idx.appBundles()
		apps := make([]installedApp, len(bundles))
		jobs := make(chan int)
		var wg sync.WaitGroup
		for range min(explainAppIndexWorkers, len(bundles)) {
			wg.Go(func() {
				for i := range jobs {
					info := filepath.Join(bundles[i], "Contents", "Info.plist")
					// A missing key is normal (many apps have no CFBundleName);
					// the bundle file name still identifies the app.
					bundleID, _ := idx.readKey(ctx, info, "CFBundleIdentifier")
					bundleName, _ := idx.readKey(ctx, info, "CFBundleName")
					apps[i] = installedApp{
						Name:       strings.TrimSuffix(filepath.Base(bundles[i]), filepath.Ext(bundles[i])),
						BundleName: bundleName,
						BundleID:   bundleID,
					}
				}
			})
		}
		for i := range bundles {
			jobs <- i
		}
		close(jobs)
		wg.Wait()

		idx.apps = apps
		idx.complete = listed && ctx.Err() == nil
	})
}

// appBundles lists the .app bundles directly inside each root. listed is
// false when a root exists but could not be read, so absence is not proven.
func (idx *explainAppIndex) appBundles() (bundles []string, listed bool) {
	listed = true
	for _, root := range idx.roots {
		root, ok := expandHomeDir(root, idx.home)
		if !ok {
			listed = false
			continue
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				listed = false
			}
			continue
		}
		for _, entry := range entries {
			if strings.EqualFold(filepath.Ext(entry.Name()), ".app") {
				bundles = append(bundles, filepath.Join(root, entry.Name()))
			}
		}
	}
	return bundles, listed
}

// expandHomeDir resolves a "~/" prefix. ok is false when the path needs a
// home directory and none is known.
func expandHomeDir(dir, home string) (string, bool) {
	rest, isHomeRelative := strings.CutPrefix(dir, "~/")
	if !isHomeRelative {
		return dir, true
	}
	if home == "" {
		return "", false
	}
	return filepath.Join(home, rest), true
}
