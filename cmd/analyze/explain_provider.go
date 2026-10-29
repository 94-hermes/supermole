//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
)

const (
	explainClaudeModel = "opus"
	// Read-only file tools for the deep pass. --restricted already strips the
	// code-running tools and confines these to the working directory.
	explainClaudeDeepTools = "Read,Glob,Grep"
	explainQuickTimeout    = 90 * time.Second
	explainDeepTimeout     = 240 * time.Second
	explainKillGrace       = 2 * time.Second
	explainErrorMaxWidth   = 160
	explainScratchPrefix   = "mole-explain-"
	explainSchemaFileName  = "schema.json"
	explainAnswerFileName  = "answer.json"
)

// explainResponseSchema is shared by both providers. Codex rejects a schema
// without additionalProperties:false, so it stays strict for both.
const explainResponseSchema = `{"type":"object","additionalProperties":false,` +
	`"properties":{"verdict":{"type":"string","enum":["safe","caution","keep","unknown"]},` +
	`"what":{"type":"string"},"if_deleted":{"type":"string"},"advice":{"type":"string"},` +
	`"needs_exploration":{"type":"boolean"}},` +
	`"required":["verdict","what","if_deleted","advice","needs_exploration"]}`

// Mole can start from launchers with a minimal PATH, so also look where the
// Claude Code and Codex installers put their binaries.
var explainBinaryDirs = []string{"/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.claude/local"}

// A child agent inheriting these believes it runs nested inside another
// Claude Code session.
var explainNestedSessionEnv = []string{"CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"}

var errExplainBinaryMissing = errors.New("introuvable")

type explainVerdict string

const (
	explainVerdictSafe    explainVerdict = "safe"
	explainVerdictCaution explainVerdict = "caution"
	explainVerdictKeep    explainVerdict = "keep"
	explainVerdictUnknown explainVerdict = "unknown"
)

func (v explainVerdict) valid() bool {
	switch v {
	case explainVerdictSafe, explainVerdictCaution, explainVerdictKeep, explainVerdictUnknown:
		return true
	default:
		return false
	}
}

type explainMode int

const (
	explainQuick explainMode = iota // metadata only, no tools
	explainDeep                     // read-only look inside the target
)

func (mode explainMode) timeout() time.Duration {
	if mode == explainDeep {
		return explainDeepTimeout
	}
	return explainQuickTimeout
}

type explanation struct {
	Verdict          explainVerdict
	What             string
	IfDeleted        string
	Advice           string
	NeedsExploration bool
	Explored         bool
	Provider         string
}

// explainResponse is the wire shape both providers fill from the schema.
type explainResponse struct {
	Verdict          explainVerdict `json:"verdict"`
	What             string         `json:"what"`
	IfDeleted        string         `json:"if_deleted"`
	Advice           string         `json:"advice"`
	NeedsExploration bool           `json:"needs_exploration"`
}

func (r explainResponse) explanation() (explanation, error) {
	if !r.Verdict.valid() {
		return explanation{}, fmt.Errorf("verdict inconnu %q", r.Verdict)
	}
	what := strings.TrimSpace(r.What)
	if what == "" {
		return explanation{}, errors.New("réponse vide")
	}
	return explanation{
		Verdict:          r.Verdict,
		What:             what,
		IfDeleted:        strings.TrimSpace(r.IfDeleted),
		Advice:           strings.TrimSpace(r.Advice),
		NeedsExploration: r.NeedsExploration,
	}, nil
}

type explainCommand struct {
	binary string
	args   []string
	dir    string
	stdin  string
}

type explainCommandRunner func(context.Context, explainCommand) ([]byte, error)

type explainBinaryFinder func(name string) (string, error)

type explainBackend struct {
	run  explainCommandRunner
	find explainBinaryFinder
}

func defaultExplainBackend() explainBackend {
	return explainBackend{run: runExplainCommand, find: findExplainBinary}
}

// explainCall is one request as every provider sees it.
type explainCall struct {
	prompt  string
	mode    explainMode
	workDir string // where the agent runs; the only directory a deep pass may read
	scratch string // private directory for schema and answer files
}

type explainProvider struct {
	label  string
	binary string
	ask    func(context.Context, explainCommandRunner, string, explainCall) (explanation, error)
}

// Claude answers first because it is the user's subscription; Codex only
// covers a missing, logged-out or failing Claude.
var explainProviders = []explainProvider{
	{label: "Claude", binary: "claude", ask: askClaude},
	{label: "Codex", binary: "codex", ask: askCodex},
}

// askExplainProviders tries each provider in order, each under its own
// timeout, and reports every failure when none answers.
func askExplainProviders(ctx context.Context, backend explainBackend, call explainCall) (explanation, error) {
	failures := make([]string, 0, len(explainProviders))
	for _, provider := range explainProviders {
		binary, err := backend.find(provider.binary)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s : %v", provider.label, err))
			continue
		}

		attemptCtx, cancel := context.WithTimeout(ctx, call.mode.timeout())
		result, err := provider.ask(attemptCtx, backend.run, binary, call)
		timedOut := errors.Is(attemptCtx.Err(), context.DeadlineExceeded)
		cancel()
		if err == nil {
			result.Provider = provider.label
			result.Explored = call.mode == explainDeep
			return result, nil
		}
		if ctx.Err() != nil {
			return explanation{}, ctx.Err()
		}
		if timedOut {
			err = fmt.Errorf("pas de réponse après %s", call.mode.timeout())
		}
		failures = append(failures, fmt.Sprintf("%s : %s", provider.label, compactExplainError(err)))
	}
	return explanation{}, errors.New(strings.Join(failures, " · "))
}

// claudeReply is the subset of `claude -p --output-format json` we read.
type claudeReply struct {
	IsError          bool             `json:"is_error"`
	Result           string           `json:"result"`
	StructuredOutput *explainResponse `json:"structured_output"`
}

func askClaude(ctx context.Context, run explainCommandRunner, binary string, call explainCall) (explanation, error) {
	tools := ""
	if call.mode == explainDeep {
		tools = explainClaudeDeepTools
	}
	// The prompt goes through stdin: --tools is variadic and would swallow a
	// positional prompt placed after it.
	output, runErr := run(ctx, explainCommand{
		binary: binary,
		args: []string{
			"-p",
			"--restricted",
			"--strict-mcp-config",
			"--no-session-persistence",
			"--model", explainClaudeModel,
			"--output-format", "json",
			"--json-schema", explainResponseSchema,
			"--system-prompt", explainSystemPrompt,
			"--tools", tools,
		},
		dir:   call.workDir,
		stdin: call.prompt,
	})
	return parseClaudeOutput(output, runErr)
}

// parseClaudeOutput prefers Claude's own error text (for example a logged-out
// account) over the bare exit status.
func parseClaudeOutput(output []byte, runErr error) (explanation, error) {
	var reply claudeReply
	decodeErr := json.Unmarshal(bytes.TrimSpace(output), &reply)
	switch {
	case decodeErr == nil && reply.IsError:
		message := strings.TrimSpace(reply.Result)
		if message == "" {
			message = "erreur sans message"
		}
		return explanation{}, errors.New(message)
	case runErr != nil:
		return explanation{}, runErr
	case decodeErr != nil:
		return explanation{}, fmt.Errorf("réponse illisible : %w", decodeErr)
	case reply.StructuredOutput == nil:
		return explanation{}, errors.New("réponse sans contenu structuré")
	}
	return reply.StructuredOutput.explanation()
}

func askCodex(ctx context.Context, run explainCommandRunner, binary string, call explainCall) (explanation, error) {
	schemaPath := filepath.Join(call.scratch, explainSchemaFileName)
	answerPath := filepath.Join(call.scratch, explainAnswerFileName)
	if err := os.WriteFile(schemaPath, []byte(explainResponseSchema), 0o600); err != nil {
		return explanation{}, fmt.Errorf("écriture du schéma : %w", err)
	}
	// --ignore-user-config keeps the user's hooks and MCP servers out of this
	// one-shot call; authentication still comes from CODEX_HOME.
	if _, err := run(ctx, explainCommand{
		binary: binary,
		args: []string{
			"exec",
			"--ephemeral",
			"--skip-git-repo-check",
			"--ignore-user-config",
			"--sandbox", "read-only",
			"--color", "never",
			"--cd", call.workDir,
			"--output-schema", schemaPath,
			"--output-last-message", answerPath,
			"-",
		},
		dir:   call.workDir,
		stdin: explainSystemPrompt + "\n\n" + call.prompt,
	}); err != nil {
		return explanation{}, err
	}
	answer, err := os.ReadFile(answerPath)
	if err != nil {
		return explanation{}, fmt.Errorf("pas de réponse : %w", err)
	}
	return parseExplainResponse(answer)
}

func parseExplainResponse(data []byte) (explanation, error) {
	var response explainResponse
	if err := json.Unmarshal(bytes.TrimSpace(data), &response); err != nil {
		return explanation{}, fmt.Errorf("réponse illisible : %w", err)
	}
	return response.explanation()
}

func runExplainCommand(ctx context.Context, command explainCommand) ([]byte, error) {
	cmd := exec.CommandContext(ctx, command.binary, command.args...)
	cmd.Dir = command.dir
	cmd.Env = explainCommandEnv(os.Environ())
	cmd.Stdin = strings.NewReader(command.stdin)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	// Agents start helper processes; kill the whole group so quitting Mole or
	// hitting a timeout leaves nothing running.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = explainKillGrace

	output, err := cmd.Output()
	if err != nil {
		if detail := lastNonEmptyLine(stderr.String()); detail != "" {
			return output, fmt.Errorf("%w : %s", err, detail)
		}
		return output, err
	}
	return output, nil
}

func explainCommandEnv(environ []string) []string {
	return slices.DeleteFunc(slices.Clone(environ), func(entry string) bool {
		key, _, _ := strings.Cut(entry, "=")
		return slices.Contains(explainNestedSessionEnv, key)
	})
}

func findExplainBinary(name string) (string, error) {
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	home, homeErr := os.UserHomeDir()
	for _, dir := range explainBinaryDirs {
		if rest, isHomeRelative := strings.CutPrefix(dir, "~/"); isHomeRelative {
			if homeErr != nil {
				continue
			}
			dir = filepath.Join(home, rest)
		}
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", errExplainBinaryMissing
}

func lastNonEmptyLine(text string) string {
	for _, line := range slices.Backward(strings.Split(strings.TrimSpace(text), "\n")) {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
}

// compactExplainError keeps a provider failure to one short panel line.
func compactExplainError(err error) string {
	message := strings.Join(strings.Fields(err.Error()), " ")
	runes := []rune(message)
	if len(runes) > explainErrorMaxWidth {
		return string(runes[:explainErrorMaxWidth-1]) + "…"
	}
	return message
}
