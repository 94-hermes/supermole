//go:build darwin

package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"time"
)

const (
	// One bounded directory read serves both the name listing and the newest
	// change, so a huge directory costs at most this many lstat calls.
	explainMaxStatChildren = 500
	explainMaxWhereFroms   = 2
	explainMaxURLWidth     = 200
	mdlsBinary             = "/usr/bin/mdls"
)

var whereFromsQuotedPattern = regexp.MustCompile(`"((?:[^"\\]|\\.)*)"`)

// explainStamp identifies the target as it was when it was explained, so a
// remembered answer can tell whether it still describes the same thing.
type explainStamp struct {
	Exists  bool
	IsDir   bool
	ModTime time.Time
}

// explainFacts is what Mole knows locally about a row. It never includes file
// contents.
type explainFacts struct {
	stamp          explainStamp
	contents       explainContents
	newestChange   time.Time // the target, or for a directory also its direct children
	owner          explainOwner
	downloadedFrom []string
}

type explainWhereFromsReader func(ctx context.Context, path string) ([]string, error)

// explainSources are the local lookups facts draw on; nil skips one.
type explainSources struct {
	apps       *explainAppIndex
	whereFroms explainWhereFromsReader
}

func defaultExplainSources() explainSources {
	return explainSources{apps: newExplainAppIndex(), whereFroms: readWhereFroms}
}

// gatherExplainFacts runs on a worker, never on the event loop.
func gatherExplainFacts(ctx context.Context, item explainJobItem, sources explainSources) explainFacts {
	target := item.target
	var facts explainFacts
	if info, err := os.Lstat(target.Path); err == nil {
		facts.stamp = explainStamp{Exists: true, IsDir: info.IsDir(), ModTime: info.ModTime()}
		facts.newestChange = info.ModTime()
	}
	if target.IsDir {
		contents, newest := readExplainDir(target.Path)
		facts.contents = contents
		if newest.After(facts.newestChange) {
			facts.newestChange = newest
		}
	}
	// The scan cache knows child sizes, which a plain listing does not.
	if item.cached != nil {
		facts.contents = *item.cached
	}
	if sources.apps != nil {
		facts.owner = sources.apps.ownerOf(ctx, target.Path)
	}
	if !target.IsDir && sources.whereFroms != nil {
		// Provenance is optional: Spotlight being off or slow only drops the hint.
		if urls, err := sources.whereFroms(ctx, target.Path); err == nil {
			facts.downloadedFrom = urls
		}
	}
	return facts
}

// readExplainDir lists names only, never sizes or file contents, and also
// returns the newest modification time among the entries it read.
func readExplainDir(path string) (explainContents, time.Time) {
	dir, err := os.Open(path)
	if err != nil {
		return explainContents{Note: explainReadFailure(err)}, time.Time{}
	}
	defer dir.Close() //nolint:errcheck

	entries, err := dir.ReadDir(explainMaxStatChildren)
	var contents explainContents
	if err != nil && !errors.Is(err, io.EOF) {
		contents.Note = explainReadFailure(err)
	}
	var newest time.Time
	for _, entry := range entries {
		// An entry removed since the listing has no time to report.
		if info, infoErr := entry.Info(); infoErr == nil && info.ModTime().After(newest) {
			newest = info.ModTime()
		}
	}

	slices.SortFunc(entries, func(a, b os.DirEntry) int { return cmp.Compare(a.Name(), b.Name()) })
	contents.Truncated = len(entries) > explainMaxListedChildren
	for _, entry := range entries[:min(len(entries), explainMaxListedChildren)] {
		contents.Children = append(contents.Children, explainChild{Name: entry.Name(), Size: -1, IsDir: entry.IsDir()})
	}
	return contents, newest
}

func explainReadFailure(err error) string {
	if isPermissionFailure(err) {
		return "contenu illisible : permission refusée"
	}
	return fmt.Sprintf("contenu illisible : %v", err)
}

func readWhereFroms(ctx context.Context, path string) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, mdlsTimeout)
	defer cancel()
	output, err := exec.CommandContext(ctx, mdlsBinary, "-name", "kMDItemWhereFroms", "-raw", path).Output()
	if err != nil {
		return nil, err
	}
	return parseWhereFroms(output), nil
}

// parseWhereFroms reads mdls -raw output: "(null)", or a parenthesized list of
// quoted strings (the download URL, then usually the page it came from).
func parseWhereFroms(output []byte) []string {
	var urls []string
	for _, match := range whereFromsQuotedPattern.FindAllSubmatch(output, -1) {
		url := strings.TrimSpace(string(match[1]))
		if url == "" {
			continue
		}
		if runes := []rune(url); len(runes) > explainMaxURLWidth {
			url = string(runes[:explainMaxURLWidth-1]) + "…"
		}
		urls = append(urls, url)
		if len(urls) == explainMaxWhereFroms {
			break
		}
	}
	return urls
}
