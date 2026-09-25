/** Project-local stage 2-4 integration. No provider calls, model changes or UI automation. */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";

export const BOOTSTRAP = "Ecosys bounded workflow: read ecosys-audit/WORKFLOW.md for audit tasks. " +
  "Pi is reviewer-only in the Herdr audit lane. Read the assigned packet and relevant source/raw evidence, " +
  "not historical handoffs. Write review artifacts only under audit/reviews/. " +
  "Submit a candidate/packet-bound result with workflow.py review; the controller handles session rotation. " +
  "Use run_logged.py for verbose commands; <=300-word terminal review, evidence by path. " +
  "No automatic commits/pushes, permission answers, or gate promotion.";

export function inside(root: string, target: string): string {
  const path = resolve(root, target.replace(/^@/, ""));
  // Resolve existing ancestors so a symlink/junction cannot bypass the write-lane check.
  let ancestor = path;
  const missing: string[] = [];
  while (true) {
    try { ancestor = realpathSync(ancestor); break; }
    catch { const parent = dirname(ancestor); if (parent === ancestor) throw new Error("Cannot resolve path"); missing.unshift(relative(parent, ancestor)); ancestor = parent; }
  }
  const canonical = resolve(ancestor, ...missing);
  const rel = relative(realpathSync(root), canonical);
  if (rel === ".." || rel.startsWith("..\\") || rel.startsWith("../") || isAbsolute(rel)) throw new Error("Path outside project");
  return canonical;
}

export function noisy(command: string): boolean {
  return !command.includes("run_logged.py") && /\b(?:zig(?:\.exe)?\s+(?:build|test)|gfortran(?:\.exe)?\b|pytest\b|ecosys_ng\.exe(?:\s|$))/i.test(command);
}

function atomic(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  const temp = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temp, JSON.stringify(value), { encoding: "utf8", flag: "wx" });
  renameSync(temp, path);
}

export default function (pi: ExtensionAPI) {
  let reminded = false;
  let root = "";
  const herdr = process.env.HERDR_ENV === "1" && !!process.env.HERDR_PANE_ID;
  const getState = (): any => {
    try { return JSON.parse(readFileSync(resolve(root, "audit/workflow/runtime/state.json"), "utf8")); }
    catch (e: any) { if (e.code === "ENOENT") return { phase: "idle" }; throw e; }
  };
  const register = (ctx: any, activity: string) => {
    if (!herdr) return;
    atomic(resolve(root, "audit/workflow/runtime/reviewer.json"), {
      session_id: ctx.sessionManager.getSessionId(), pane_id: process.env.HERDR_PANE_ID,
      role: "reviewer", activity, updated: Date.now() / 1000,
    });
  };
  pi.on("session_start", (_event, ctx) => {
    root = ctx.cwd;
    reminded = false;
    register(ctx, "idle");
  });
  pi.on("before_agent_start", (event) => {
    reminded = false;
    // Stable section, not a per-turn snapshot of volatile state or the whole handoff.
    event.systemPromptOptions.sections ??= {};
    event.systemPromptOptions.sections.ecosys_workflow = BOOTSTRAP;
  });
  pi.on("agent_start", (_event, ctx) => register(ctx, "working"));
  pi.on("agent_settled", (_event, ctx) => register(ctx, "idle"));
  pi.on("agent_before_settle", (event, ctx) => {
    const s = getState();
    if (!herdr || reminded || s.phase !== "review") return;
    let dispatch: any;
    try { dispatch = JSON.parse(readFileSync(resolve(root, "audit/workflow/runtime/dispatch.json"), "utf8")); }
    catch (e: any) { if (e.code === "ENOENT") return; throw e; }
    if (dispatch.role !== "reviewer" || dispatch.session_id !== ctx.sessionManager.getSessionId()) return;
    try { readFileSync(resolve(root, `audit/reviews/${s.task}-r${s.revision}.json`)); return; }
    catch (e: any) { if (e.code !== "ENOENT") throw e; }
    reminded = true;
    return {
      entries: [...event.entries, { type: "custom_message", customType: "ecosys-review-receipt",
        content: "Before yielding, submit the existing scoped review through workflow.py review with your session ID, packet digest, findings and evidence. If blocked, submit BLOCKED, not PASS. No new investigation or repeated tests. This reminder runs once.", display: false }],
      continue: true,
    };
  });
  pi.on("tool_call", (event) => {
    const input = event.input as any;
    if (["write", "edit"].includes(event.toolName)) {
      const reviewerLane = herdr && getState().phase === "review";
      let path: string;
      try { path = inside(root, input.path); }
      catch (error) { if (reviewerLane) throw error; return; }
      if (path === resolve(root, "audit/handoff.md")) return { block: true, reason: "Only the lead updates the handoff through workflow.py checkpoint; raw writes lose archival/CAS protection." };
      if (reviewerLane) {
        const rel = relative(resolve(root, "audit/reviews"), path);
        if (rel === ".." || rel.startsWith("..\\") || rel.startsWith("../") || isAbsolute(rel))
          return { block: true, reason: "Reviewer lane: write only audit/reviews/. Propose implementation changes to Claude in the review." };
      }
    }
    if (["bash", "powershell"].includes(event.toolName) && noisy(input.command ?? ""))
      return { block: true, reason: "Use run_logged.py --cwd <cwd> --out audit/reviews/<unique-dir> --timeout <seconds> -- <argv>. Raw logs persist; bounded receipt returns. Outer tool timeout must exceed wrapper timeout by 60s. Tests require the lead's assignment." };
  });
  pi.on("tool_result", (event) => {
    if (!["bash", "powershell"].includes(event.toolName)) return;
    if (event.content.some((c: any) => c.type !== "text")) return; // Do not discard images/structured content.
    const text = event.content.map((c: any) => c.text).join("\n");
    if (Buffer.byteLength(text, "utf8") <= 8000) return;
    const folder = resolve(root, "audit/reviews/captured-tool-results");
    mkdirSync(folder, { recursive: true });
    const path = resolve(folder, `${randomUUID()}.txt`);
    writeFileSync(path, text, { encoding: "utf8", flag: "wx" });
    const sha = createHash("sha256").update(text).digest("hex");
    return { content: [{ type: "text" as const, text:
      `[Captured tool result shortened; underlying tool may already have truncated the raw command output. Use run_logged.py for full raw streams. File: ${relative(root, path)} SHA256=${sha}]\n` +
      text.slice(0, 1800) + "\n[... omitted from context; inspect file as needed ...]\n" + text.slice(-2200) }] };
  });
}
