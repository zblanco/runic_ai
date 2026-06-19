#!/usr/bin/env node

const fs = require("fs");
const http = require("http");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const requestPath = process.argv[2];

if (!requestPath) {
  console.error("usage: browser_ui_runner.js REQUEST_JSON");
  process.exit(64);
}

const request = JSON.parse(fs.readFileSync(requestPath, "utf8"));
const outputDir = request.output_dir;
fs.mkdirSync(outputDir, { recursive: true });

const prefix = safeLabel(request.scenario_id || "scenario");
const htmlPath = path.join(outputDir, `${prefix}-session.html`);
const domSnapshotPath = path.join(outputDir, `${prefix}-session-dom.txt`);
const screenshotPath = path.join(outputDir, `${prefix}-session.png`);
const consolePath = path.join(outputDir, `${prefix}-console.json`);
const networkPath = path.join(outputDir, `${prefix}-network.json`);
const rawOutputPath = path.join(outputDir, `${prefix}-browser-ui-runner.json`);
const stagePath = path.join(outputDir, `${prefix}-stages.json`);
const profileDir = path.join(outputDir, "chrome-cdp-profile");

const consoleEvents = [];
const networkEvents = [];
const browserOutput = [];
const stages = [];

main()
  .then((result) => {
    fs.writeFileSync(rawOutputPath, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  })
  .catch((error) => {
    const result = {
      enabled: true,
      status: "failed",
      message: error && error.stack ? error.stack : String(error),
      raw_output_path: rawOutputPath,
      stage_path: writeJson(stagePath, stages),
      console_path: writeJson(consolePath, consoleEvents),
      network_path: writeJson(networkPath, networkEvents),
    };
    fs.writeFileSync(rawOutputPath, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
    process.exitCode = 1;
  });

async function main() {
  const chrome = request.chrome_executable;
  if (!chrome) {
    throw new Error("chrome_executable is required");
  }

  fs.mkdirSync(profileDir, { recursive: true });

  const chromeProcess = spawn(chrome, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-background-networking",
    "--disable-sync",
    "--disable-extensions",
    "--hide-scrollbars",
    "--remote-debugging-port=0",
    "--window-size=1440,1000",
    `--user-data-dir=${profileDir}`,
    "about:blank",
  ]);

  chromeProcess.stdout.on("data", (data) => browserOutput.push(data.toString()));
  chromeProcess.stderr.on("data", (data) => browserOutput.push(data.toString()));

  const devtools = await waitForDevtools(profileDir, request.timeout_ms || 30000);
  const page = await firstPage(devtools.port);
  const cdp = await CDP.connect(page.webSocketDebuggerUrl);

  try {
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Log.enable");
    await cdp.send("Network.enable");

    cdp.on("Runtime.consoleAPICalled", (params) => {
      consoleEvents.push({
        type: params.type,
        text: (params.args || []).map((arg) => arg.value || arg.description || "").join(" "),
        timestamp: params.timestamp,
      });
    });

    cdp.on("Runtime.exceptionThrown", (params) => {
      consoleEvents.push({
        type: "exception",
        text: params.exceptionDetails && params.exceptionDetails.text,
        details: params.exceptionDetails,
      });
    });

    cdp.on("Log.entryAdded", (params) => {
      consoleEvents.push(params.entry);
    });

    cdp.on("Network.responseReceived", (params) => {
      networkEvents.push({
        type: "response",
        url: params.response && params.response.url,
        status: params.response && params.response.status,
        mimeType: params.response && params.response.mimeType,
        resourceType: params.type,
      });
    });

    cdp.on("Network.loadingFailed", (params) => {
      networkEvents.push({
        type: "failed",
        requestId: params.requestId,
        resourceType: params.type,
        errorText: params.errorText,
        canceled: params.canceled,
      });
    });

    const openExistingSession = !!request.open_session_url;
    const initialUrl = request.open_session_url || request.base_url;

    await cdp.send("Page.navigate", { url: initialUrl });
    await waitFor(cdp, async () => {
      const text = await evalValue(cdp, "(() => document.body && document.body.innerText)()");
      return String(text || "").includes("RunicAI");
    }, request.timeout_ms || 30000);

    let formState = null;

    if (openExistingSession) {
      await waitForConnectedSession(cdp, request.timeout_ms || 30000);
      formState = {
        skipped: true,
        reason: "opened existing session URL",
        location: await evalValue(cdp, "(() => window.location.href)()"),
      };
    } else {
      await waitForConnectedWorkbench(cdp, request.timeout_ms || 30000);
      formState = await submitWorkbenchObjective(cdp, request.launch);
    }

    stages.push({ stage: "submitted", formState });
    fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));

    if (!openExistingSession) {
      await waitFor(cdp, async () => {
        const url = await evalValue(cdp, "(() => window.location.href)()");
        return String(url || "").includes("/sessions/");
      }, request.timeout_ms || 30000);
    }

    await selectPlanTab(cdp, request.timeout_ms || 30000);
    await delay(request.active_progress_capture_delay_ms || 250);
    const activePlanEvidence = await waitForActivePlanEvidence(cdp, request.active_progress_wait_ms || 10000);
    stages.push({ stage: "active_plan_snapshot", planEvidence: activePlanEvidence });
    fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));

    let reviewDecisionState = null;
    if (request.review_decision) {
      await maybeClick(cdp, '[phx-click="set_workspace_tab"][phx-value-tab="reviews"]');
      await delay(250);
      reviewDecisionState = await submitReviewDecisionWhenVisible(cdp, request.review_decision, request.timeout_ms || 30000);
      stages.push({ stage: "review_decision", formState: reviewDecisionState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    await selectPlanTab(cdp, request.timeout_ms || 30000);
    await waitForPlanAgentFinished(cdp, request.pre_terminal_grace_ms || 5000).catch(() => null);
    await delay(250);

    let followUpState = null;
    let injectedFailureState = null;
    if (request.follow_up_prompt) {
      injectedFailureState = injectRepairFailure(request);
      const followUpLaunch = {
        ...request.launch,
        objective: followUpObjective(request.follow_up_prompt, injectedFailureState),
        session_id: sessionIdFromUrl(await evalValue(cdp, "(() => window.location.href)()")) || request.launch.session_id,
      };

      await waitForConnectedWorkbench(cdp, request.timeout_ms || 30000);
      followUpState = await submitWorkbenchObjective(cdp, followUpLaunch);
      stages.push({ stage: "follow_up_submitted", formState: followUpState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));

      const followUpNeedle = String(request.follow_up_prompt).slice(0, 80);
      await waitFor(cdp, async () => {
        const text = await evalValue(cdp, "(() => document.body && document.body.innerText)()");
        return String(text || "").includes(followUpNeedle);
      }, request.timeout_ms || 30000).catch(() => null);

      await selectPlanTab(cdp, request.timeout_ms || 30000);
      await waitForPlanAgentFinished(cdp, request.pre_terminal_grace_ms || 5000).catch(() => null);
      await selectPlanTab(cdp, request.timeout_ms || 30000);
    }

    const terminalWaitState = await waitForPlanTerminalOrStable(cdp, request.terminal_wait_ms || request.timeout_ms || 30000);
    stages.push({ stage: "terminal_wait", state: terminalWaitState });
    fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));

    const finalUrl = await evalValue(cdp, "(() => window.location.href)()");
    const capturedSessionId = sessionIdFromUrl(finalUrl) || request.launch.session_id;
    const sessionUrl = canonicalSessionUrl(request.base_url, capturedSessionId, finalUrl);
    await selectPlanTab(cdp, request.timeout_ms || 30000);
    const planEvidence = await collectPlanEvidence(cdp);
    const html = await evalValue(cdp, "(() => document.documentElement.outerHTML)()");
    const domText = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
    const screenshot = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });

    fs.writeFileSync(htmlPath, String(html || ""));
    fs.writeFileSync(domSnapshotPath, String(domText || ""));
    fs.writeFileSync(screenshotPath, Buffer.from(screenshot.data || "", "base64"));
    fs.writeFileSync(consolePath, JSON.stringify(consoleEvents, null, 2));
    fs.writeFileSync(networkPath, JSON.stringify(networkEvents, null, 2));

    const result = {
      enabled: true,
      status: "ok",
      base_url: request.base_url,
      session_url: sessionUrl,
      session_id: capturedSessionId,
      html_path: htmlPath,
      dom_snapshot_path: domSnapshotPath,
      screenshot_path: screenshotPath,
      screenshot_byte_size: fs.statSync(screenshotPath).size,
      console_path: consolePath,
      console_count: consoleEvents.length,
      console_error_count: consoleEvents.filter((event) => ["error", "exception"].includes(event.type || event.level)).length,
      "console_captured?": true,
      network_path: networkPath,
      network_count: networkEvents.length,
      network_failure_count: networkEvents.filter((event) => event.type === "failed").length,
      "network_captured?": true,
      "ui_launch_captured?": true,
      "existing_session_opened?": openExistingSession,
      "plan_visibility_captured?": planEvidence["plan_visible?"],
      "workflow_stage_plan_visible?": planEvidence["workflow_stages_visible?"],
      "live_progress_visible?": planEvidence["live_progress_visible?"],
      "active_progress_snapshot_captured?": activePlanEvidence["live_progress_visible?"] || planEvidence["live_progress_visible?"],
      "active_progress_current_context_visible?": activePlanEvidence["current_context_visible?"] || planEvidence["current_context_visible?"],
      "active_progress_child_visible?": activePlanEvidence["child_visible?"] || planEvidence["child_visible?"],
      "active_progress_remaining_visible?": activePlanEvidence["remaining_visible?"] || planEvidence["remaining_visible?"],
      "active_progress_budget_visible?": activePlanEvidence["runtime_budget_visible?"] || planEvidence["runtime_budget_visible?"],
      "active_progress_pre_final_visible?": activePlanEvidence["pre_final_visible?"],
      "active_progress_pre_final_required?": !!request["active_progress_pre_final_required?"],
      active_plan_text_preview: activePlanEvidence.text_preview,
      "terminal_wait_observed?": !!terminalWaitState.observed,
      terminal_wait_state: terminalWaitState,
      plan_stage_labels: planEvidence.stage_labels,
      plan_text_preview: planEvidence.text_preview,
      "repair_failure_injection_enabled?": !!request.repair_failure_injection,
      "repair_failure_injected?": !!(injectedFailureState && injectedFailureState.injected),
      "repair_failure_observed?": !!(injectedFailureState && injectedFailureState.command && injectedFailureState.command.status !== 0),
      injected_failure_state: injectedFailureState,
      "review_decision_required?": !!request.review_decision,
      "review_card_captured?": !!(reviewDecisionState && reviewDecisionState.found),
      "review_decision_captured?": !!(reviewDecisionState && reviewDecisionState.submitted),
      review_decision_state: reviewDecisionState,
      "browser_follow_up_required?": !!request.follow_up_prompt,
      "browser_follow_up_captured?": !!(followUpState && followUpState.liveViewSubmit && followUpState.liveViewSubmit.ok),
      "tidewave_interaction_captured?": !!(followUpState && followUpState.liveViewSubmit && followUpState.liveViewSubmit.ok),
      form_state: formState,
      follow_up_state: followUpState,
      chrome_executable: chrome,
      raw_output_path: rawOutputPath,
      stage_path: stagePath,
      browser_output_preview: browserOutput.join("").slice(0, 1200),
    };

    await cdp.send("Browser.close").catch(() => null);
    return result;
  } finally {
    cdp.close();
    chromeProcess.kill("SIGTERM");
  }
}

function injectRepairFailure(request) {
  const injection = request.repair_failure_injection;
  if (!injection) return null;

  const root = request.workspace_root;
  if (!root) return { injected: false, reason: "workspace_root missing" };

  const written = [];
  for (const [relative, content] of Object.entries(injection.files || {})) {
    const target = safeWorkspacePath(root, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, String(content || ""));
    written.push(relative);
  }

  let command = null;
  if (Array.isArray(injection.command) && injection.command.length > 0) {
    const [exe, ...args] = injection.command;
    const result = spawnSync(exe, args, {
      cwd: root,
      encoding: "utf8",
      timeout: injection.timeout_ms || 30000,
      env: { ...process.env, MIX_ENV: "test" },
    });

    command = {
      argv: injection.command,
      status: result.status,
      signal: result.signal,
      error: result.error ? String(result.error) : null,
      output_preview: `${result.stdout || ""}${result.stderr || ""}`.slice(-4000),
    };
  }

  return { injected: true, written, command };
}

function safeWorkspacePath(root, relative) {
  const target = path.resolve(root, relative);
  const expandedRoot = path.resolve(root);
  if (target !== expandedRoot && !target.startsWith(expandedRoot + path.sep)) {
    throw new Error(`repair failure injection path escapes workspace: ${relative}`);
  }
  return target;
}

function followUpObjective(prompt, injectedFailureState) {
  if (!injectedFailureState || !injectedFailureState.command) return prompt;

  return `${prompt}

Observed failing smoke before this follow-up:
${JSON.stringify(injectedFailureState.command, null, 2)}`;
}

async function collectPlanEvidence(cdp) {
  const text = await evalValue(cdp, `(() => {
    const panels = Array.from(document.querySelectorAll('section[role="tabpanel"]'));
    const visiblePanels = panels.filter((panel) => {
      const style = window.getComputedStyle(panel);
      return style.display !== "none" && style.visibility !== "hidden" && panel.offsetParent !== null;
    });
    const planMarkers = (panel) => {
      const text = String(panel && panel.innerText || "").toLowerCase();
      return text.includes("live progress") ||
        text.includes("objective contract") ||
        (text.includes("01 objective") && text.includes("06 review"));
    };
    const panel = visiblePanels.find(planMarkers) || panels.find(planMarkers) || visiblePanels[0];
    return panel ? panel.innerText : "";
  })()`);
  const normalized = String(text || "").toLowerCase();
  const labels = ["objective", "planning", "implementation", "verification", "repair", "review"]
    .filter((label) => normalized.includes(label));
  const lines = String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim().toLowerCase())
    .filter(Boolean);

  const childVisible = lines.some((line) => line.includes("child"));
  const remainingVisible = lines.some((line) => line.includes("remaining"));
  const currentContextVisible = lines.some((line) =>
    line.includes("current node") ||
    line.includes("current_node") ||
    line.includes("node started") ||
    line.includes("node_started") ||
    line === "node" ||
    line.includes("active node")
  );

  return {
    "plan_visible?": labels.includes("objective") && labels.includes("review"),
    "workflow_stages_visible?": ["planning", "implementation", "verification", "repair"].every((label) => labels.includes(label)),
    "live_progress_visible?": normalized.includes("live progress") && normalized.includes("persisted events"),
    "current_context_visible?": currentContextVisible || childVisible,
    "child_visible?": childVisible,
    "remaining_visible?": remainingVisible,
    "pre_final_visible?": normalized.includes("live progress") && !normalized.includes("agent finished"),
    "runtime_budget_visible?": remainingVisible || lines.includes("child budget") || lines.includes("max"),
    stage_labels: labels,
    text_preview: String(text || "").slice(0, 1200),
  };
}

async function waitForPlanAgentFinished(cdp, timeoutMs) {
  return waitFor(cdp, async () => {
    const evidence = await collectPlanEvidence(cdp);
    return String(evidence.text_preview || "").toLowerCase().includes("agent finished");
  }, timeoutMs);
}

async function waitForActivePlanEvidence(cdp, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let latest = await collectPlanEvidence(cdp);

  while (Date.now() < deadline) {
    latest = await collectPlanEvidence(cdp);
    if (
      latest["live_progress_visible?"] &&
      latest["remaining_visible?"] &&
      (latest["current_context_visible?"] || terminalOrReviewText(latest.text_preview))
    ) {
      return {...latest, observed: true};
    }
    await delay(200);
  }

  return {...latest, observed: false, reason: "active progress context not observed before timeout"};
}

async function waitForPlanTerminalOrStable(cdp, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let latest = await collectPlanEvidence(cdp);

  while (Date.now() < deadline) {
    latest = await collectPlanEvidence(cdp);
    if (terminalOrReviewText(latest.text_preview)) {
      return {observed: true, reason: "terminal or review checkpoint observed", planEvidence: latest};
    }
    await delay(250);
  }

  return {observed: false, reason: "terminal or review checkpoint not observed before timeout", planEvidence: latest};
}

function terminalOrReviewText(text) {
  const normalized = String(text || "").toLowerCase();
  return (
    normalized.includes("agent finished") ||
    normalized.includes("review required") ||
    normalized.includes("needs review approval") ||
    normalized.includes("blocked-run evidence") ||
    normalized.includes("objective\ncompleted") ||
    normalized.includes("objective\nfailed")
  );
}

async function selectPlanTab(cdp, timeoutMs) {
  const deadline = Date.now() + Math.min(timeoutMs || 30000, 5000);

  while (Date.now() < deadline) {
    await maybeClick(cdp, '[phx-click="set_workspace_tab"][phx-value-tab="plan"]');
    await delay(200);

    const evidence = await collectPlanEvidence(cdp);
    if (evidence["plan_visible?"] || evidence["live_progress_visible?"]) {
      return true;
    }
  }

  return false;
}

async function waitForConnectedWorkbench(cdp, timeoutMs) {
  return waitFor(cdp, async () => {
    return await evalValue(cdp, `(() => {
      const form = document.querySelector('form[phx-submit="submit_objective"]');
      if (!form || !window.liveSocket || !window.liveSocket.owner) return false;
      const view = window.liveSocket.owner(form);
      return !!(view && view.isConnected && view.isConnected());
    })()`);
  }, timeoutMs);
}

async function waitForConnectedSession(cdp, timeoutMs) {
  return waitFor(cdp, async () => {
    return await evalValue(cdp, `(() => {
      if (!window.liveSocket || !window.liveSocket.owner || !document.body) return false;
      const candidate =
        document.querySelector('form[phx-submit="review_decision"]') ||
        document.querySelector('form[phx-submit="submit_objective"]') ||
        document.querySelector('[data-phx-main]');
      if (!candidate) return false;

      try {
        const view = window.liveSocket.owner(candidate);
        return !!(view && view.isConnected && view.isConnected());
      } catch (_error) {
        return false;
      }
    })()`);
  }, timeoutMs);
}

async function submitWorkbenchObjective(cdp, values) {
  return evalValue(cdp, `(async () => {
    const values = ${JSON.stringify(values)};
    const forms = Array.from(document.querySelectorAll('form[phx-submit="submit_objective"]'));
    const form = forms.find((candidate) => candidate.offsetParent !== null) || forms[forms.length - 1];
    if (!form) return {found: false, reason: "submit_objective form not found"};
    const setValue = (name, value) => {
      let el = form.querySelector('[name="run[' + name + ']"]');
      if (value === undefined || value === null) return null;
      if (!el) {
        el = document.createElement("input");
        el.type = "hidden";
        el.name = "run[" + name + "]";
        form.appendChild(el);
      }
      el.value = String(value);
      el.dispatchEvent(new Event("input", {bubbles: true}));
      el.dispatchEvent(new Event("change", {bubbles: true}));
      return el.value;
    };
    const assigned = {};
    for (const [key, value] of Object.entries(values)) assigned[key] = setValue(key, value);
    const button = form.querySelector('button[type="submit"]');
    const liveViewSubmit = await new Promise((resolve) => {
      const liveSocket = window.liveSocket;
      if (!liveSocket || !liveSocket.owner) {
        resolve({ok: false, reason: "window.liveSocket.owner unavailable"});
        return;
      }

      const timeout = setTimeout(() => {
        resolve({ok: false, reason: "liveview submit timeout"});
      }, 5000);

      try {
        const view = liveSocket.owner(form);
        if (!view) {
          clearTimeout(timeout);
          resolve({ok: false, reason: "liveSocket owner not found"});
          return;
        }

        if (!view.submitForm) {
          clearTimeout(timeout);
          resolve({ok: false, reason: "owner view submitForm unavailable"});
          return;
        }

        view.submitForm(form, form, form.getAttribute("phx-submit"), button || null, {});
        clearTimeout(timeout);
        resolve({ok: true, dispatched: true, phxSubmit: form.getAttribute("phx-submit")});
      } catch (error) {
        clearTimeout(timeout);
        resolve({ok: false, reason: error && error.message ? error.message : String(error)});
      }
    });
    return {
      found: true,
      assigned,
      liveViewSubmit,
      location: window.location.href,
      prompt: values.objective,
    };
  })()`);
}

async function submitReviewDecisionWhenVisible(cdp, decision, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastState = null;

  while (Date.now() < deadline) {
    const state = await submitReviewDecision(cdp, decision);
    if (state && state.found) {
      lastState = state;
      if (state.submitted) return state;
    }
    await delay(150);
  }

  return lastState || { found: false, submitted: false, reason: "review_decision form not found before timeout" };
}

async function submitReviewDecision(cdp, decision) {
  return evalValue(cdp, `(async () => {
    const decision = ${JSON.stringify(decision || {})};
    const forms = Array.from(document.querySelectorAll('form[phx-submit="review_decision"]'));
    const form = forms.find((candidate) => candidate.offsetParent !== null) || forms[forms.length - 1];
    if (!form) return {found: false, submitted: false, reason: "review_decision form not found"};

    const id = form.querySelector('[name="review[id]"]')?.value;
    const rewrite = decision.rewrite === undefined || decision.rewrite === null ? "" : String(decision.rewrite);
    const action = decision.action || "approve";
    const rewriteEl = form.querySelector('[name="review[rewrite]"]');
    if (rewriteEl) {
      rewriteEl.value = rewrite;
      rewriteEl.dispatchEvent(new Event("input", {bubbles: true}));
      rewriteEl.dispatchEvent(new Event("change", {bubbles: true}));
    }

    const liveViewSubmit = await new Promise((resolve) => {
      const liveSocket = window.liveSocket;
      if (!liveSocket || !liveSocket.owner) {
        resolve({ok: false, reason: "window.liveSocket.owner unavailable"});
        return;
      }

      const timeout = setTimeout(() => {
        resolve({ok: false, reason: "liveview review decision timeout"});
      }, 5000);

      try {
        const view = liveSocket.owner(form);
        if (!view || !view.submitForm) {
          clearTimeout(timeout);
          resolve({ok: false, reason: "owner view submitForm unavailable"});
          return;
        }

        if (!view.isConnected || !view.isConnected()) {
          clearTimeout(timeout);
          resolve({ok: false, reason: "owner view disconnected"});
          return;
        }

        const button =
          form.querySelector('button[name="review[action]"][value="' + CSS.escape(action) + '"]') ||
          form.querySelector('button[type="submit"]');
        view.submitForm(form, form, form.getAttribute("phx-submit"), button || null, {});
        clearTimeout(timeout);
        resolve({ok: true, dispatched: true, phxSubmit: form.getAttribute("phx-submit")});
      } catch (error) {
        clearTimeout(timeout);
        resolve({ok: false, reason: error && error.message ? error.message : String(error)});
      }
    });

    return {
      found: true,
      submitted: !!liveViewSubmit.ok,
      id,
      action,
      rewrite,
      liveViewSubmit,
      location: window.location.href,
      textPreview: document.body ? document.body.innerText.slice(0, 1000) : "",
    };
  })()`);
}

async function maybeClick(cdp, selector) {
  return evalValue(cdp, `(() => {
    const selector = ${JSON.stringify(selector)};
    const el = document.querySelector(selector);
    if (!el) return false;
    el.click();
    return true;
  })()`).catch(() => false);
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2));
  return filePath;
}

function safeLabel(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") || "scenario";
}

function sessionIdFromUrl(url) {
  const match = String(url || "").match(/\/sessions\/([^/?#]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

function canonicalSessionUrl(baseUrl, sessionId, fallbackUrl) {
  if (!sessionId) return fallbackUrl;

  try {
    const url = new URL(baseUrl || fallbackUrl);
    url.pathname = `/sessions/${encodeURIComponent(sessionId)}`;
    url.hash = "";
    return url.toString();
  } catch (_error) {
    return fallbackUrl;
  }
}

async function waitForDevtools(profileDir, timeoutMs) {
  const activePortPath = path.join(profileDir, "DevToolsActivePort");
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    if (fs.existsSync(activePortPath)) {
      const [port] = fs.readFileSync(activePortPath, "utf8").trim().split(/\n/);
      return { port };
    }
    await delay(50);
  }

  throw new Error("timed out waiting for Chrome DevToolsActivePort");
}

function firstPage(port) {
  return new Promise((resolve, reject) => {
    http.get({ host: "127.0.0.1", port, path: "/json/list" }, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        try {
          const pages = JSON.parse(body);
          const page = pages.find((entry) => entry.type === "page") || pages[0];
          if (!page || !page.webSocketDebuggerUrl) reject(new Error("no debuggable Chrome page found"));
          else resolve(page);
        } catch (error) {
          reject(error);
        }
      });
    }).on("error", reject);
  });
}

async function waitFor(cdp, predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await delay(100);
  }
  throw new Error("wait timed out");
}

async function evalValue(cdp, expression, args = []) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  });

  return result.result && result.result.value;
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class CDP {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();

    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result || {});
      } else if (message.method) {
        const handlers = this.handlers.get(message.method) || [];
        for (const handler of handlers) handler(message.params || {});
      }
    });
  }

  static connect(url) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      socket.addEventListener("open", () => resolve(new CDP(socket)));
      socket.addEventListener("error", reject);
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  on(method, handler) {
    const handlers = this.handlers.get(method) || [];
    handlers.push(handler);
    this.handlers.set(method, handlers);
  }

  close() {
    this.socket.close();
  }
}
