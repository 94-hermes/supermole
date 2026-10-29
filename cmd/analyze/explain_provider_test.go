//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

const fakeClaudeSuccess = `{"is_error":false,"result":"","structured_output":` +
	`{"verdict":"caution","what":"Des faux iPhone pour Xcode.","if_deleted":"Tu perds leurs apps.",` +
	`"advice":"Passe par Xcode.","needs_exploration":false}}`

const fakeCodexAnswer = `{"verdict":"safe","what":"Un cache.","if_deleted":"Il revient tout seul.",` +
	`"advice":"Supprime-le.","needs_exploration":false}`

func argAfter(t *testing.T, args []string, flag string) string {
	t.Helper()
	i := slices.Index(args, flag)
	if i < 0 || i+1 >= len(args) {
		t.Fatalf("flag %s missing from %q", flag, args)
	}
	return args[i+1]
}

func TestAskClaudeQuickRunsRestrictedWithoutTools(t *testing.T) {
	var got explainCommand
	run := func(_ context.Context, command explainCommand) ([]byte, error) {
		got = command
		return []byte(fakeClaudeSuccess), nil
	}
	call := explainCall{prompt: "Élément à expliquer", mode: explainQuick, workDir: t.TempDir()}

	result, err := askClaude(context.Background(), run, "/bin/claude", call)
	if err != nil {
		t.Fatalf("askClaude() error = %v", err)
	}
	if result.Verdict != explainVerdictCaution || result.What != "Des faux iPhone pour Xcode." {
		t.Fatalf("askClaude() = %+v", result)
	}
	for _, flag := range []string{"-p", "--restricted", "--strict-mcp-config", "--no-session-persistence"} {
		if !slices.Contains(got.args, flag) {
			t.Fatalf("missing %s in %q", flag, got.args)
		}
	}
	if tools := argAfter(t, got.args, "--tools"); tools != "" {
		t.Fatalf("quick pass tools = %q, want none", tools)
	}
	if model := argAfter(t, got.args, "--model"); model != explainClaudeModel {
		t.Fatalf("model = %q", model)
	}
	if got.dir != call.workDir || got.stdin != call.prompt {
		t.Fatalf("dir=%q stdin=%q, want workDir and prompt on stdin", got.dir, got.stdin)
	}
	if got.args[len(got.args)-1] == call.prompt {
		t.Fatal("prompt must not follow the variadic --tools flag")
	}
}

func TestAskClaudeDeepAllowsOnlyReadOnlyTools(t *testing.T) {
	var got explainCommand
	run := func(_ context.Context, command explainCommand) ([]byte, error) {
		got = command
		return []byte(fakeClaudeSuccess), nil
	}
	target := t.TempDir()

	if _, err := askClaude(context.Background(), run, "/bin/claude", explainCall{mode: explainDeep, workDir: target}); err != nil {
		t.Fatalf("askClaude() error = %v", err)
	}
	if tools := argAfter(t, got.args, "--tools"); tools != explainClaudeDeepTools {
		t.Fatalf("deep pass tools = %q", tools)
	}
	if !slices.Contains(got.args, "--restricted") || got.dir != target {
		t.Fatalf("deep pass must stay restricted to the target: args=%q dir=%q", got.args, got.dir)
	}
}

func TestParseClaudeOutput(t *testing.T) {
	exitErr := errors.New("exit status 1")
	tests := []struct {
		name    string
		output  string
		runErr  error
		wantErr string
	}{
		{name: "structured answer", output: fakeClaudeSuccess},
		{name: "claude error text wins over exit status", output: `{"is_error":true,"result":"Not logged in · Please run /login"}`, runErr: exitErr, wantErr: "Not logged in"},
		{name: "exit without json", output: "boom", runErr: exitErr, wantErr: "exit status 1"},
		{name: "unreadable output", output: "not json", wantErr: "réponse illisible"},
		{name: "missing structured output", output: `{"is_error":false,"result":"texte libre"}`, wantErr: "sans contenu structuré"},
		{name: "unknown verdict", output: `{"structured_output":{"verdict":"maybe","what":"x"}}`, wantErr: "verdict inconnu"},
		{name: "empty answer", output: `{"structured_output":{"verdict":"safe","what":"  "}}`, wantErr: "réponse vide"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := parseClaudeOutput([]byte(tt.output), tt.runErr)
			if tt.wantErr == "" {
				if err != nil || result.Verdict != explainVerdictCaution {
					t.Fatalf("parseClaudeOutput() = %+v, %v", result, err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("parseClaudeOutput() error = %v, want %q", err, tt.wantErr)
			}
		})
	}
}

func TestAskCodexUsesEphemeralReadOnlySandbox(t *testing.T) {
	scratch := t.TempDir()
	workDir := t.TempDir()
	var got explainCommand
	run := func(_ context.Context, command explainCommand) ([]byte, error) {
		got = command
		answerPath := argAfter(t, command.args, "--output-last-message")
		return nil, os.WriteFile(answerPath, []byte(fakeCodexAnswer), 0o600)
	}
	call := explainCall{prompt: "Élément à expliquer", mode: explainQuick, workDir: workDir, scratch: scratch}

	result, err := askCodex(context.Background(), run, "/bin/codex", call)
	if err != nil {
		t.Fatalf("askCodex() error = %v", err)
	}
	if result.Verdict != explainVerdictSafe {
		t.Fatalf("askCodex() = %+v", result)
	}
	for _, flag := range []string{"exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config"} {
		if !slices.Contains(got.args, flag) {
			t.Fatalf("missing %s in %q", flag, got.args)
		}
	}
	if sandbox := argAfter(t, got.args, "--sandbox"); sandbox != "read-only" {
		t.Fatalf("sandbox = %q", sandbox)
	}
	if cd := argAfter(t, got.args, "--cd"); cd != workDir {
		t.Fatalf("--cd = %q, want %q", cd, workDir)
	}
	schema, err := os.ReadFile(argAfter(t, got.args, "--output-schema"))
	if err != nil || string(schema) != explainResponseSchema {
		t.Fatalf("schema file = %q, %v", schema, err)
	}
	if !strings.Contains(got.stdin, explainSystemPrompt) || !strings.HasSuffix(got.stdin, call.prompt) {
		t.Fatalf("codex stdin must carry the instructions then the prompt: %q", got.stdin)
	}
}

func TestAskCodexRejectsMalformedAnswer(t *testing.T) {
	run := func(_ context.Context, command explainCommand) ([]byte, error) {
		return nil, os.WriteFile(argAfter(t, command.args, "--output-last-message"), []byte("```json"), 0o600)
	}
	_, err := askCodex(context.Background(), run, "/bin/codex", explainCall{workDir: t.TempDir(), scratch: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "réponse illisible") {
		t.Fatalf("askCodex() error = %v", err)
	}
}

// fakeExplainBackend answers per binary name: "claude" and "codex" map to
// either an output or a failure, and a missing key means not installed.
func fakeExplainBackend(t *testing.T, answers map[string]error, calls *[]string) explainBackend {
	t.Helper()
	return explainBackend{
		find: func(name string) (string, error) {
			if _, ok := answers[name]; !ok {
				return "", errExplainBinaryMissing
			}
			return "/fake/" + name, nil
		},
		run: func(_ context.Context, command explainCommand) ([]byte, error) {
			name := filepath.Base(command.binary)
			*calls = append(*calls, name)
			if err := answers[name]; err != nil {
				return nil, err
			}
			if name == "codex" {
				return nil, os.WriteFile(argAfter(t, command.args, "--output-last-message"), []byte(fakeCodexAnswer), 0o600)
			}
			return []byte(fakeClaudeSuccess), nil
		},
	}
}

func TestAskExplainProvidersFallsBackToCodex(t *testing.T) {
	tests := []struct {
		name      string
		answers   map[string]error
		wantCalls []string
		wantLabel string
		wantErr   []string
	}{
		{name: "claude answers", answers: map[string]error{"claude": nil, "codex": nil}, wantCalls: []string{"claude"}, wantLabel: "Claude"},
		{name: "claude missing", answers: map[string]error{"codex": nil}, wantCalls: []string{"codex"}, wantLabel: "Codex"},
		{name: "claude fails", answers: map[string]error{"claude": errors.New("Not logged in"), "codex": nil}, wantCalls: []string{"claude", "codex"}, wantLabel: "Codex"},
		{
			name:      "both fail",
			answers:   map[string]error{"claude": errors.New("Not logged in"), "codex": errors.New("quota")},
			wantCalls: []string{"claude", "codex"},
			wantErr:   []string{"Claude : Not logged in", "Codex : quota"},
		},
		{name: "neither installed", answers: map[string]error{}, wantErr: []string{"Claude : introuvable", "Codex : introuvable"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var calls []string
			backend := fakeExplainBackend(t, tt.answers, &calls)
			call := explainCall{mode: explainQuick, workDir: t.TempDir(), scratch: t.TempDir()}

			result, err := askExplainProviders(context.Background(), backend, call)
			if !slices.Equal(calls, tt.wantCalls) {
				t.Fatalf("calls = %q, want %q", calls, tt.wantCalls)
			}
			if len(tt.wantErr) > 0 {
				for _, want := range tt.wantErr {
					if err == nil || !strings.Contains(err.Error(), want) {
						t.Fatalf("error = %v, want it to mention %q", err, want)
					}
				}
				return
			}
			if err != nil || result.Provider != tt.wantLabel {
				t.Fatalf("result = %+v, err = %v, want provider %s", result, err, tt.wantLabel)
			}
		})
	}
}

func TestAskExplainProvidersStopsWhenCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var calls []string
	backend := fakeExplainBackend(t, map[string]error{"claude": nil, "codex": nil}, &calls)
	backend.run = func(context.Context, explainCommand) ([]byte, error) {
		calls = append(calls, "claude")
		cancel()
		return nil, context.Canceled
	}

	_, err := askExplainProviders(ctx, backend, explainCall{workDir: t.TempDir(), scratch: t.TempDir()})
	if !errors.Is(err, context.Canceled) || len(calls) != 1 {
		t.Fatalf("err = %v, calls = %q: quitting must not fall back to Codex", err, calls)
	}
}

func TestAskExplainProvidersMarksDeepAnswersExplored(t *testing.T) {
	var calls []string
	backend := fakeExplainBackend(t, map[string]error{"claude": nil}, &calls)
	for _, mode := range []explainMode{explainQuick, explainDeep} {
		result, err := askExplainProviders(context.Background(), backend, explainCall{mode: mode, workDir: t.TempDir(), scratch: t.TempDir()})
		if err != nil || result.Explored != (mode == explainDeep) {
			t.Fatalf("mode %d: result = %+v, err = %v", mode, result, err)
		}
	}
}

func TestExplainCommandEnvDropsNestedSessionMarkers(t *testing.T) {
	environ := []string{"PATH=/usr/bin", "CLAUDECODE=1", "CLAUDE_CODE_ENTRYPOINT=cli", "CLAUDECODE_EXTRA=kept", "HOME=/Users/me"}
	got := explainCommandEnv(environ)
	want := []string{"PATH=/usr/bin", "CLAUDECODE_EXTRA=kept", "HOME=/Users/me"}
	if !slices.Equal(got, want) {
		t.Fatalf("explainCommandEnv() = %q, want %q", got, want)
	}
	if len(environ) != 5 {
		t.Fatal("explainCommandEnv must not modify the caller's slice")
	}
}

func TestFindExplainBinaryUsesPath(t *testing.T) {
	dir := t.TempDir()
	binary := filepath.Join(dir, "mole-explain-fake-agent")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	if got, err := findExplainBinary("mole-explain-fake-agent"); err != nil || got != binary {
		t.Fatalf("findExplainBinary() = %q, %v", got, err)
	}
	if _, err := findExplainBinary("mole-explain-missing-agent"); !errors.Is(err, errExplainBinaryMissing) {
		t.Fatalf("missing binary error = %v", err)
	}
}

func TestRunExplainCommandPassesStdinAndReportsStderr(t *testing.T) {
	output, err := runExplainCommand(context.Background(), explainCommand{binary: "/bin/cat", stdin: "bonjour"})
	if err != nil || string(output) != "bonjour" {
		t.Fatalf("cat output = %q, %v", output, err)
	}

	_, err = runExplainCommand(context.Background(), explainCommand{binary: "/bin/sh", args: []string{"-c", "echo first >&2; echo 'Not logged in' >&2; exit 3"}})
	if err == nil || !strings.Contains(err.Error(), "Not logged in") {
		t.Fatalf("failure error = %v, want the last stderr line", err)
	}
}

func TestRunExplainCommandKillsProcessGroupOnCancel(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	script := fmt.Sprintf("sleep 30 & echo $! > %s; wait", pidFile)

	start := time.Now()
	_, err := runExplainCommand(ctx, explainCommand{binary: "/bin/sh", args: []string{"-c", script}})
	if err == nil {
		t.Fatal("canceled command reported success")
	}
	if elapsed := time.Since(start); elapsed > explainKillGrace+time.Second {
		t.Fatalf("cancel took %s; the group kill or WaitDelay is not applied", elapsed)
	}

	data, readErr := os.ReadFile(pidFile)
	if readErr != nil {
		t.Fatalf("child pid not recorded: %v", readErr)
	}
	var pid int
	if _, scanErr := fmt.Sscan(string(data), &pid); scanErr != nil {
		t.Fatalf("child pid %q: %v", data, scanErr)
	}
	deadline := time.Now().Add(explainKillGrace)
	for processAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("grandchild %d survived the cancel", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func processAlive(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return process.Signal(syscall.Signal(0)) == nil
}
