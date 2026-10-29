//go:build darwin

package main

import (
	"bytes"
	"cmp"
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
	// A batch writes one answer per row in a single reply.
	explainBatchTimeout   = 180 * time.Second
	explainDeepTimeout    = 240 * time.Second
	explainKillGrace      = 2 * time.Second
	explainErrorMaxWidth  = 160
	explainScratchPrefix  = "mole-explain-"
	explainSchemaFileName = "schema.json"
	explainAnswerFileName = "answer.json"
)

// explainResponseSchema is the one reply shape for a single row, a batch and a
// deep look: a list of items keyed by the id the prompt gave each row. Codex
// rejects a schema without additionalProperties:false, so it stays strict.
const explainResponseSchema = `{"type":"object","additionalProperties":false,` +
	`"properties":{"items":{"type":"array","items":{"type":"object","additionalProperties":false,` +
	`"properties":{"id":{"type":"string"},` +
	`"verdict":{"type":"string","enum":["safe","caution","keep","unknown"]},` +
	`"what":{"type":"string"},"if_deleted":{"type":"string"},"advice":{"type":"string"},` +
	`"needs_exploration":{"type":"boolean"}},` +
	`"required":["id","verdict","what","if_deleted","advice","needs_exploration"]}}},` +
	`"required":["items"]}`

// Mole can start from launchers with a minimal PATH, so also look where the
// Claude Code and Codex installers put their binaries.
var explainBinaryDirs = []string{"/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.claude/local"}

// A child agent inheriting these believes it runs nested inside another
// Claude Code session.
var explainNestedSessionEnv = []string{"CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"}

var (
	errExplainBinaryMissing = errors.New("introuvable")
	errExplainNoUsableItem  = errors.New("aucune réponse exploitable")
)

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

type explanation struct {
	Verdict          explainVerdict
	What             string
	IfDeleted        string
	Advice           string
	NeedsExploration bool
	Explored         bool
	Provider         string
}

// explainItemResponse is one row of the reply both providers fill from the schema.
type explainItemResponse struct {
	ID               string         `json:"id"`
	Verdict          explainVerdict `json:"verdict"`
	What             string         `json:"what"`
	IfDeleted        string         `json:"if_deleted"`
	Advice           string         `json:"advice"`
	NeedsExploration bool           `json:"needs_exploration"`
}

type explainItemsResponse struct {
	Items []explainItemResponse `json:"items"`
}

func (r explainItemResponse) explanation() (explanation, error) {
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

// decodeExplainItems validates every item on its own, so one malformed row
// does not discard the rest of a batch. Items whose id the prompt did not use
// are ignored; the reply is usable once one requested id comes back valid.
func decodeExplainItems(reply json.RawMessage, ids []string) (map[string]explanation, error) {
	var response explainItemsResponse
	if err := json.Unmarshal(reply, &response); err != nil {
		return nil, fmt.Errorf("réponse illisible : %w", err)
	}
	answers := make(map[string]explanation, len(ids))
	var firstErr error
	for _, item := range response.Items {
		if _, seen := answers[item.ID]; seen || !slices.Contains(ids, item.ID) {
			continue
		}
		result, err := item.explanation()
		if err != nil {
			firstErr = cmp.Or(firstErr, err)
			continue
		}
		answers[item.ID] = result
	}
	if len(answers) == 0 {
		return nil, cmp.Or(firstErr, errExplainNoUsableItem)
	}
	return answers, nil
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
	timeout time.Duration
	workDir string // where the agent runs; the only directory a deep pass may read
	scratch string // private directory for schema and answer files
}

type explainProvider struct {
	label  string
	binary string
	ask    func(context.Context, explainCommandRunner, string, explainCall) (json.RawMessage, error)
}

// Claude answers first because it is the user's subscription; Codex only
// covers a missing, logged-out or failing Claude.
var explainProviders = []explainProvider{
	{label: "Claude", binary: "claude", ask: askClaude},
	{label: "Codex", binary: "codex", ask: askCodex},
}

// askExplainProviders tries each provider in order, each under the call's
// timeout, until one returns a reply that accept takes. A rejected reply falls
// through to the next provider like a failed run. It returns the label of the
// provider that answered, or every failure when none did.
func askExplainProviders(ctx context.Context, backend explainBackend, call explainCall, accept func(json.RawMessage) error) (string, error) {
	failures := make([]string, 0, len(explainProviders))
	for _, provider := range explainProviders {
		binary, err := backend.find(provider.binary)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s : %v", provider.label, err))
			continue
		}

		attemptCtx, cancel := context.WithTimeout(ctx, call.timeout)
		reply, err := provider.ask(attemptCtx, backend.run, binary, call)
		timedOut := errors.Is(attemptCtx.Err(), context.DeadlineExceeded)
		cancel()
		if err == nil {
			err = accept(reply)
		}
		if err == nil {
			return provider.label, nil
		}
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		if timedOut {
			err = fmt.Errorf("pas de réponse après %s", call.timeout)
		}
		failures = append(failures, fmt.Sprintf("%s : %s", provider.label, compactExplainError(err)))
	}
	return "", errors.New(strings.Join(failures, " · "))
}

// claudeReply is the subset of `claude -p --output-format json` we read.
type claudeReply struct {
	IsError          bool            `json:"is_error"`
	Result           string          `json:"result"`
	StructuredOutput json.RawMessage `json:"structured_output"`
}

func askClaude(ctx context.Context, run explainCommandRunner, binary string, call explainCall) (json.RawMessage, error) {
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
func parseClaudeOutput(output []byte, runErr error) (json.RawMessage, error) {
	var reply claudeReply
	decodeErr := json.Unmarshal(bytes.TrimSpace(output), &reply)
	switch {
	case decodeErr == nil && reply.IsError:
		message := strings.TrimSpace(reply.Result)
		if message == "" {
			message = "erreur sans message"
		}
		return nil, errors.New(message)
	case runErr != nil:
		return nil, runErr
	case decodeErr != nil:
		return nil, fmt.Errorf("réponse illisible : %w", decodeErr)
	case len(reply.StructuredOutput) == 0 || string(reply.StructuredOutput) == "null":
		return nil, errors.New("réponse sans contenu structuré")
	}
	return reply.StructuredOutput, nil
}

func askCodex(ctx context.Context, run explainCommandRunner, binary string, call explainCall) (json.RawMessage, error) {
	schemaPath := filepath.Join(call.scratch, explainSchemaFileName)
	answerPath := filepath.Join(call.scratch, explainAnswerFileName)
	if err := os.WriteFile(schemaPath, []byte(explainResponseSchema), 0o600); err != nil {
		return nil, fmt.Errorf("écriture du schéma : %w", err)
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
		return nil, err
	}
	answer, err := os.ReadFile(answerPath)
	if err != nil {
		return nil, fmt.Errorf("pas de réponse : %w", err)
	}
	return bytes.TrimSpace(answer), nil
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
	// Without a home directory only the system locations are searched.
	home, homeErr := os.UserHomeDir()
	if homeErr != nil {
		home = ""
	}
	for _, dir := range explainBinaryDirs {
		dir, ok := expandHomeDir(dir, home)
		if !ok {
			continue
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
