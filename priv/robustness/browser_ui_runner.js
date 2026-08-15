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
const inspectorHtmlPath = path.join(outputDir, `${prefix}-inspector.html`);
const inspectorDomSnapshotPath = path.join(outputDir, `${prefix}-inspector-dom.txt`);
const inspectorScreenshotPath = path.join(outputDir, `${prefix}-inspector.png`);
const consolePath = path.join(outputDir, `${prefix}-console.json`);
const networkPath = path.join(outputDir, `${prefix}-network.json`);
const rawOutputPath = path.join(outputDir, `${prefix}-browser-ui-runner.json`);
const stagePath = path.join(outputDir, `${prefix}-stages.json`);
const profileDir = path.join(outputDir, `chrome-cdp-profile-${process.pid}`);

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
      const expected = request.workflow_review_study
        ? "Counterbalanced workflow review study"
        : "RunicAI";
      return String(text || "").toLowerCase().includes(expected.toLowerCase());
    }, request.timeout_ms || 30000);

    if (request.workflow_review_study) {
      return await exerciseWorkflowReviewStudy(cdp, request, {
        htmlPath,
        domSnapshotPath,
        screenshotPath,
        consolePath,
        networkPath,
        rawOutputPath,
        stagePath,
        consoleEvents,
        networkEvents,
        browserOutput,
        chrome,
      });
    }

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
    const initialTerminalWaitState = await waitForPlanTerminalOrStable(
      cdp,
      request.terminal_wait_ms || request.timeout_ms || 30000,
    );
    stages.push({ stage: "initial_terminal_wait", state: initialTerminalWaitState });
    fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));

    let followUpState = null;
    let injectedFailureState = null;
    if (request.follow_up_prompt) {
      if (!initialTerminalWaitState.observed) {
        throw new Error("initial run did not reach a terminal or review checkpoint before follow-up");
      }

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
    }

    const terminalWaitState = await waitForPlanTerminalOrStable(cdp, request.terminal_wait_ms || request.timeout_ms || 30000);
    stages.push({ stage: "terminal_wait", state: terminalWaitState });
    fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));

    let workflowLifecycleState = null;
    if (request.workflow_lifecycle) {
      workflowLifecycleState = await exerciseWorkflowLifecycle(
        cdp,
        request.workflow_lifecycle,
        request.timeout_ms || 30000,
      );
      stages.push({ stage: "workflow_lifecycle", state: workflowLifecycleState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    let workflowStartState = null;
    let workflowIntentRunState = null;
    if (request.workflow_intent_run) {
      workflowIntentRunState = await runReviewedIntentWorkflow(
        cdp,
        request.workflow_intent_run,
        request.timeout_ms || 30000,
      );
      stages.push({ stage: "workflow_intent_run", state: workflowIntentRunState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    let workflowExactReuseState = null;
    if (request.workflow_exact_reuse) {
      workflowExactReuseState = await runExactReuseWorkflow(
        cdp,
        request,
        request.workflow_exact_reuse,
        request.timeout_ms || 30000,
      );
      stages.push({ stage: "workflow_exact_reuse", state: workflowExactReuseState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    if (request.start_pending_workflow) {
      workflowStartState = await startPendingWorkflow(cdp, request.timeout_ms || 30000);
      stages.push({ stage: "workflow_start", state: workflowStartState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    let workflowRuntimeReviewState = null;
    if (request.workflow_runtime_review) {
      workflowRuntimeReviewState = await startAndPauseWorkflowForReview(
        cdp,
        request.workflow_runtime_review,
        request.timeout_ms || 30000,
      );
      stages.push({ stage: "workflow_runtime_review", state: workflowRuntimeReviewState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    let awaitedWorkflowState = null;
    if (request.await_workflow_run) {
      awaitedWorkflowState = await awaitWorkflowRun(
        cdp,
        request.await_workflow_run,
        request.timeout_ms || 30000,
      );
      stages.push({ stage: "await_workflow_run", state: awaitedWorkflowState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    let workflowChildRestartState = null;
    if (request.workflow_child_restart) {
      workflowChildRestartState = await restartFailedWorkflowChild(
        cdp,
        request.workflow_child_restart,
        request.timeout_ms || 30000,
      );
      stages.push({ stage: "workflow_child_restart", state: workflowChildRestartState });
      fs.writeFileSync(stagePath, JSON.stringify(stages, null, 2));
    }

    const finalUrl = await evalValue(cdp, "(() => window.location.href)()");
    const capturedSessionId = sessionIdFromUrl(finalUrl) || request.launch.session_id;
    const sessionUrl = canonicalSessionUrl(request.base_url, capturedSessionId, finalUrl);
    await selectPlanTab(cdp, request.timeout_ms || 30000);
    const planEvidence = await collectPlanEvidence(cdp);
    const planFocusState = request.plan_capture_text_needle
      ? await focusVisibleText(cdp, request.plan_capture_text_needle, request.timeout_ms || 30000)
      : null;
    const html = await evalValue(cdp, "(() => document.documentElement.outerHTML)()");
    const domText = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
    const screenshot = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });

    fs.writeFileSync(htmlPath, String(html || ""));
    fs.writeFileSync(domSnapshotPath, String(domText || ""));
    fs.writeFileSync(screenshotPath, Buffer.from(screenshot.data || "", "base64"));

    const inspectorCapture = await captureInspectorTab(cdp, request);
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
      inspector_capture: inspectorCapture,
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
      plan_focus_state: planFocusState,
      "plan_focus_required?": !!request.plan_capture_text_needle,
      "plan_focus_captured?": !!(planFocusState && planFocusState.focused),
      "repair_failure_injection_enabled?": !!request.repair_failure_injection,
      "repair_failure_injected?": !!(injectedFailureState && injectedFailureState.injected),
      "repair_failure_observed?": !!(injectedFailureState && injectedFailureState.command && injectedFailureState.command.status !== 0),
      injected_failure_state: injectedFailureState,
      "review_decision_required?": !!request.review_decision,
      "review_card_captured?": !!(reviewDecisionState && reviewDecisionState.found),
      "review_decision_captured?": !!(reviewDecisionState && reviewDecisionState.submitted),
      review_decision_state: reviewDecisionState,
      workflow_lifecycle_state: workflowLifecycleState,
      "workflow_lifecycle_required?": !!request.workflow_lifecycle,
      "workflow_lifecycle_captured?": !!(workflowLifecycleState && workflowLifecycleState.completed),
      workflow_start_state: workflowStartState,
      "workflow_start_required?": !!request.start_pending_workflow,
      "workflow_start_captured?": !!(workflowStartState && workflowStartState.completed),
      workflow_intent_run_state: workflowIntentRunState,
      "workflow_intent_run_required?": !!request.workflow_intent_run,
      "workflow_intent_run_captured?": !!(workflowIntentRunState && workflowIntentRunState.completed),
      workflow_exact_reuse_state: workflowExactReuseState,
      "workflow_exact_reuse_required?": !!request.workflow_exact_reuse,
      "workflow_exact_reuse_captured?": !!(workflowExactReuseState && workflowExactReuseState.completed),
      workflow_runtime_review_state: workflowRuntimeReviewState,
      "workflow_runtime_review_required?": !!request.workflow_runtime_review,
      "workflow_runtime_review_captured?": !!(workflowRuntimeReviewState && workflowRuntimeReviewState.review_pending),
      awaited_workflow_state: awaitedWorkflowState,
      "await_workflow_run_required?": !!request.await_workflow_run,
      "await_workflow_run_captured?": !!(awaitedWorkflowState && awaitedWorkflowState.completed),
      workflow_child_restart_state: workflowChildRestartState,
      "workflow_child_restart_required?": !!request.workflow_child_restart,
      "workflow_child_restart_captured?": !!(workflowChildRestartState && workflowChildRestartState.completed),
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

async function exerciseWorkflowReviewStudy(cdp, request, paths) {
  const timeoutMs = request.timeout_ms || 30000;
  const config = request.workflow_review_study || {};

  const begin = await maybeClick(cdp, "#begin-review-study");
  if (!begin) throw new Error("workflow review study begin button not found");

  await waitFor(cdp, async () => {
    return !!(await evalValue(cdp, "(() => document.querySelector('#review-study-task'))()"));
  }, timeoutMs);

  const arm = await evalValue(cdp, `(() => {
    const semantic = document.querySelector('[data-study-arm="semantic"]');
    const raw = document.querySelector('[data-study-arm="raw_json"]');
    return semantic ? "semantic" : (raw ? "raw_json" : null);
  })()`);

  if (!arm) throw new Error("assigned workflow review study arm was not rendered");

  const taskDomPath = paths.domSnapshotPath.replace("-session-dom.txt", "-review-task-dom.txt");
  const taskScreenshotPath = paths.screenshotPath.replace("-session.png", "-review-task.png");
  const taskText = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
  const taskScreenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
  });
  fs.writeFileSync(taskDomPath, String(taskText || ""));
  fs.writeFileSync(taskScreenshotPath, Buffer.from(taskScreenshot.data || "", "base64"));

  const submit = await evalValue(cdp, `(() => {
    const answers = ${JSON.stringify(config.answers || {})};
    const form = document.querySelector('#review-study-form');
    if (!form) return {ok: false, reason: "study form missing"};

    for (const [question, answer] of Object.entries(answers)) {
      const selector = 'input[name="answers[' + question + ']"][value="' + answer + '"]';
      const input = form.querySelector(selector);
      if (!input) return {ok: false, reason: "answer input missing", question, answer};
      input.click();
    }

    const button = form.querySelector('button[type="submit"]');
    if (!button) return {ok: false, reason: "submit button missing"};
    button.click();
    return {ok: true};
  })()`);

  if (!submit || !submit.ok) {
    throw new Error(`workflow review study submit failed: ${JSON.stringify(submit)}`);
  }

  await waitFor(cdp, async () => {
    return !!(await evalValue(cdp, "(() => document.querySelector('#review-study-result'))()"));
  }, timeoutMs);

  const resultText = await evalValue(
    cdp,
    "(() => document.querySelector('#review-study-result').innerText)()",
  );
  const html = await evalValue(cdp, "(() => document.documentElement.outerHTML)()");
  const domText = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
  const screenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
  });

  fs.writeFileSync(paths.htmlPath, String(html || ""));
  fs.writeFileSync(paths.domSnapshotPath, String(domText || ""));
  fs.writeFileSync(paths.screenshotPath, Buffer.from(screenshot.data || "", "base64"));
  fs.writeFileSync(paths.consolePath, JSON.stringify(paths.consoleEvents, null, 2));
  fs.writeFileSync(paths.networkPath, JSON.stringify(paths.networkEvents, null, 2));

  const result = {
    enabled: true,
    status: "ok",
    study_url: request.open_session_url || request.base_url,
    study_arm: arm,
    task_dom_snapshot_path: taskDomPath,
    task_screenshot_path: taskScreenshotPath,
    task_screenshot_byte_size: fs.statSync(taskScreenshotPath).size,
    result_text: String(resultText || ""),
    html_path: paths.htmlPath,
    dom_snapshot_path: paths.domSnapshotPath,
    screenshot_path: paths.screenshotPath,
    screenshot_byte_size: fs.statSync(paths.screenshotPath).size,
    console_path: paths.consolePath,
    console_count: paths.consoleEvents.length,
    console_error_count: paths.consoleEvents.filter((event) =>
      ["error", "exception"].includes(event.type || event.level)
    ).length,
    network_path: paths.networkPath,
    network_count: paths.networkEvents.length,
    network_failure_count: paths.networkEvents.filter((event) => event.type === "failed").length,
    "study_completed?": String(resultText || "").toLowerCase().includes("result recorded"),
    chrome_executable: paths.chrome,
    raw_output_path: paths.rawOutputPath,
    stage_path: writeJson(paths.stagePath, [
      {stage: "review_study_completed", arm, result_text: String(resultText || "")},
    ]),
    browser_output_preview: paths.browserOutput.join("").slice(0, 1200),
  };

  await cdp.send("Browser.close").catch(() => null);
  return result;
}

async function exerciseWorkflowLifecycle(cdp, config, timeoutMs) {
  const artifactsTab = '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]';
  if (!(await maybeClick(cdp, artifactsTab))) throw new Error("artifacts inspector tab not found");

  await waitFor(cdp, async () => {
    const found = await evalValue(cdp, "(() => !!document.querySelector('form[phx-submit=\"apply_workflow_operations\"]'))()");
    return !!found;
  }, timeoutMs);

  const operations = JSON.stringify(config.operations || [
    {op: "set_policy", key: "max_runtime_ms", value: 5000},
  ]);

  const submit = await evalValue(cdp, `(() => {
    const form = document.querySelector('form[phx-submit="apply_workflow_operations"]');
    if (!form) return {ok: false, reason: "workflow edit form missing"};
    const textarea = form.querySelector('textarea[name="workflow_edit[operations]"]');
    if (!textarea) return {ok: false, reason: "operations textarea missing"};
    textarea.value = ${JSON.stringify(operations)};
    textarea.dispatchEvent(new Event("input", {bubbles: true}));
    const view = window.liveSocket && window.liveSocket.owner && window.liveSocket.owner(form);
    if (!view || !view.submitForm) return {ok: false, reason: "owner view submitForm unavailable"};
    view.submitForm(form, form, form.getAttribute("phx-submit"), form.querySelector('button[type="submit"]'), {});
    return {ok: true};
  })()`);

  if (!submit || !submit.ok) throw new Error(`workflow edit submit failed: ${JSON.stringify(submit)}`);

  const revision = Number(config.expected_revision || 2);
  await waitForBodyText(cdp, `latest revision ${revision}`, timeoutMs);

  const comparison = config.compare_revisions
    ? await exerciseWorkflowRevisionComparison(
        cdp,
        Number(config.compare_from_revision || 1),
        Number(config.compare_to_revision || revision),
        timeoutMs,
      )
    : null;

  const actions = [
    ["request_review", "Approve revision"],
    ["approve", "Activate revision"],
    ["activate", "lifecycle activated"],
  ];

  const completedActions = [];
  for (const [action, expectedText] of actions) {
    const selector = `[phx-click="workflow_definition_action"][phx-value-action="${action}"]`;
    if (!(await maybeClick(cdp, selector))) throw new Error(`workflow lifecycle action missing: ${action}`);
    await waitForBodyText(cdp, expectedText, timeoutMs);
    completedActions.push(action);
  }

  const forkSelector = '[phx-click="fork_workflow_run"]';
  if (!(await maybeClick(cdp, forkSelector))) throw new Error("workflow fork action missing");
  await waitForBodyText(cdp, "Forked run", timeoutMs);

  const suggestion = config.suggested_edit
    ? await exerciseWorkflowEditSuggestion(cdp, config.suggested_edit, revision + 1, timeoutMs)
    : null;

  return {
    completed: true,
    revision,
    operations: config.operations,
    comparison,
    actions: completedActions,
    forked: true,
    suggestion,
  };
}

async function exerciseWorkflowEditSuggestion(cdp, config, expectedRevision, timeoutMs) {
  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');
  const operations = JSON.stringify(config.operations || [
    {op: "set_policy", key: "max_steps", value: 10},
  ]);

  const submit = await evalValue(cdp, `(() => {
    const form = document.querySelector('form[phx-submit="apply_workflow_operations"]');
    if (!form) return {ok: false, reason: "workflow edit form missing"};
    const textarea = form.querySelector('textarea[name="workflow_edit[operations]"]');
    const button = form.querySelector('button[name="workflow_edit[action]"][value="suggest"]');
    if (!textarea || !button) return {ok: false, reason: "suggested edit controls missing"};
    textarea.value = ${JSON.stringify(operations)};
    textarea.dispatchEvent(new Event("input", {bubbles: true}));
    const view = window.liveSocket && window.liveSocket.owner && window.liveSocket.owner(form);
    if (!view || !view.submitForm) return {ok: false, reason: "owner view submitForm unavailable"};
    view.submitForm(form, form, form.getAttribute("phx-submit"), button, {});
    return {ok: true};
  })()`);

  if (!submit || !submit.ok) {
    throw new Error(`workflow edit suggestion submit failed: ${JSON.stringify(submit)}`);
  }

  await maybeClick(cdp, '[phx-click="set_workspace_tab"][phx-value-tab="reviews"]');
  await waitFor(cdp, async () => {
    const found = await evalValue(cdp, `(() => !!document.querySelector(
      'form[phx-submit="review_decision"] input[name="review[id]"][value^="workflow_edit_review:"]'
    ))()`);
    return !!found;
  }, timeoutMs);
  const reviewId = await evalValue(cdp, `(() => {
    const input = document.querySelector(
      'form[phx-submit="review_decision"] input[name="review[id]"][value^="workflow_edit_review:"]'
    );
    return input && input.value;
  })()`);
  if (!reviewId) throw new Error("workflow edit suggestion review id missing");

  const reviewText = await evalValue(cdp, `(() => {
    const input = document.querySelector(
      'form[phx-submit="review_decision"] input[name="review[id]"][value^="workflow_edit_review:"]'
    );
    const card = input && input.closest('.runic-review-card');
    return card ? card.innerText : "";
  })()`);
  if (!String(reviewText || "").includes("max_steps")) {
    throw new Error(`workflow edit semantic diff missing from review card: ${String(reviewText || "").slice(0, 1000)}`);
  }

  const approveSelector = `form[phx-submit="review_decision"]:has(input[value^="workflow_edit_review:"]) button[name="review[action]"][value="approve"]`;
  if (!(await maybeClick(cdp, approveSelector))) {
    throw new Error("workflow edit suggestion approve action missing");
  }
  await waitForBodyText(cdp, "Review decision recorded", timeoutMs);

  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');
  await waitForBodyText(cdp, `latest revision ${expectedRevision}`, timeoutMs);

  return {
    completed: true,
    review_id: reviewId,
    expected_revision: expectedRevision,
    operations: config.operations,
    review_text: String(reviewText || "").slice(0, 2000),
  };
}

async function exerciseWorkflowRevisionComparison(cdp, fromRevision, toRevision, timeoutMs) {
  const submit = await evalValue(cdp, `(() => {
    const form = document.querySelector('form[phx-submit="compare_workflow_revisions"]');
    if (!form) return {ok: false, reason: "workflow comparison form missing"};
    const from = form.querySelector('select[name="workflow_compare[from_revision_id]"]');
    const to = form.querySelector('select[name="workflow_compare[to_revision_id]"]');
    if (!from || !to) return {ok: false, reason: "workflow comparison selectors missing"};
    const selectRevision = (select, revision) => {
      const option = Array.from(select.options).find((candidate) =>
        String(candidate.textContent || "").trim().startsWith("revision " + revision + " ")
      );
      if (!option) return false;
      select.value = option.value;
      select.dispatchEvent(new Event("input", {bubbles: true}));
      select.dispatchEvent(new Event("change", {bubbles: true}));
      return true;
    };
    if (!selectRevision(from, ${JSON.stringify(fromRevision)})) {
      return {ok: false, reason: "from revision option missing"};
    }
    if (!selectRevision(to, ${JSON.stringify(toRevision)})) {
      return {ok: false, reason: "to revision option missing"};
    }
    const view = window.liveSocket && window.liveSocket.owner && window.liveSocket.owner(form);
    if (!view || !view.submitForm) return {ok: false, reason: "owner view submitForm unavailable"};
    view.submitForm(form, form, form.getAttribute("phx-submit"), form.querySelector('button[type="submit"]'), {});
    return {ok: true};
  })()`);

  if (!submit || !submit.ok) {
    throw new Error(`workflow revision comparison failed: ${JSON.stringify(submit)}`);
  }

  await waitForBodyText(cdp, `Revision ${fromRevision} → ${toRevision}`, timeoutMs);
  const text = await evalValue(cdp, `(() => {
    const comparison = document.querySelector('[id^="workflow-revision-comparison-"]');
    return comparison ? comparison.innerText : "";
  })()`);

  return {
    completed: true,
    from_revision: fromRevision,
    to_revision: toRevision,
    text: String(text || "").slice(0, 2000),
  };
}

async function waitForBodyText(cdp, needle, timeoutMs) {
  await waitFor(cdp, async () => {
    const text = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
    return String(text || "").includes(String(needle));
  }, timeoutMs);
}

async function focusVisibleText(cdp, needle, timeoutMs) {
  await waitForBodyText(cdp, needle, timeoutMs);

  const state = await evalValue(cdp, `(() => {
    const needle = ${JSON.stringify(String(needle))};
    const candidates = Array.from(document.querySelectorAll('dd, p, span, li, article, section'));
    const target = candidates
      .filter((element) => {
        const text = String(element.innerText || element.textContent || "");
        return text.includes(needle) && element.offsetParent !== null;
      })
      .sort((left, right) => String(left.innerText || left.textContent || "").length -
        String(right.innerText || right.textContent || "").length)[0];
    if (!target) return {focused: false, reason: "visible text element not found"};
    target.scrollIntoView({block: "center", inline: "nearest"});
    return {focused: true, tag: target.tagName, text: String(target.innerText || target.textContent || "").slice(0, 500)};
  })()`);

  await delay(250);
  return state;
}

async function runReviewedIntentWorkflow(cdp, config, timeoutMs) {
  await selectPlanTab(cdp, timeoutMs);

  for (const expected of config.expected_text || []) {
    await waitForBodyText(cdp, String(expected), timeoutMs);
  }

  const actions = [
    ["approve", "Activate revision"],
    ["activate", "Create pinned run"],
  ];

  for (const [action, expectedText] of actions) {
    const selector = `[phx-click="workflow_definition_action"][phx-value-action="${action}"][phx-value-definition-id]`;
    await waitFor(cdp, async () => {
      return !!(await evalValue(cdp, `(() => !!document.querySelector(${JSON.stringify(selector)}))()`));
    }, timeoutMs);
    if (!(await maybeClick(cdp, selector))) throw new Error(`intent workflow action missing: ${action}`);
    await waitForBodyText(cdp, expectedText, timeoutMs);
  }

  const launchSelector = '[phx-click="launch_workflow_definition"][phx-value-definition-id]';
  if (!(await maybeClick(cdp, launchSelector))) throw new Error("intent workflow launch action missing");
  await waitForBodyText(cdp, "Start pinned revision", timeoutMs);

  const started = await startPendingWorkflow(cdp, timeoutMs);
  return {...started, approved: true, activated: true, launched: true};
}

async function runExactReuseWorkflow(cdp, request, config, timeoutMs) {
  await cdp.send("Page.navigate", { url: request.base_url });
  await waitFor(cdp, async () => {
    const text = await evalValue(cdp, "(() => document.body && document.body.innerText)()");
    return String(text || "").includes("RunicAI");
  }, timeoutMs);
  await waitForConnectedWorkbench(cdp, timeoutMs);

  const launch = {
    ...request.launch,
    orchestration: config.orchestration || "auto",
    session_id: config.session_id || `${request.launch.session_id}-exact-reuse`,
  };

  const formState = await submitWorkbenchObjective(cdp, launch);
  await waitFor(cdp, async () => {
    const url = await evalValue(cdp, "(() => window.location.href)()");
    return String(url || "").includes("/sessions/");
  }, timeoutMs);

  await selectPlanTab(cdp, timeoutMs);
  for (const expected of config.expected_text || ["Proven workflow selected"]) {
    await waitForBodyText(cdp, String(expected), timeoutMs);
  }

  const terminal = await waitForPlanTerminalOrStable(cdp, timeoutMs);
  if (!terminal.observed) throw new Error("exact-reuse session did not reach a terminal state");

  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');
  await waitFor(cdp, async () => {
    return !!(await evalValue(cdp, `(() => Array.from(document.querySelectorAll('[id^="workflow-run-"]'))
      .some((row) => row.getAttribute('data-run-status') === 'completed' && String(row.innerText || '').includes('intent_reuse')))()`));
  }, timeoutMs);

  const run = await evalValue(cdp, `(() => {
    const row = Array.from(document.querySelectorAll('[id^="workflow-run-"]'))
      .find((candidate) => candidate.getAttribute('data-run-status') === 'completed' &&
        String(candidate.innerText || '').includes('intent_reuse'));
    return row ? {
      id: row.id.replace(/^workflow-run-/, ''),
      status: row.getAttribute('data-run-status'),
      text: String(row.innerText || '').slice(0, 1200),
    } : null;
  })()`);

  return {
    completed: !!run,
    form_state: formState,
    session_id: sessionIdFromUrl(await evalValue(cdp, "(() => window.location.href)()")),
    run,
    terminal,
  };
}

async function startPendingWorkflow(cdp, timeoutMs) {
  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');
  await waitFor(cdp, async () => {
    const found = await evalValue(cdp, "(() => !!document.querySelector('[phx-click=\"start_workflow_run\"]'))()");
    return !!found;
  }, timeoutMs);
  const runId = await evalValue(cdp, `(() => {
    const button = document.querySelector('[phx-click="start_workflow_run"]');
    return button && button.getAttribute('phx-value-run-id');
  })()`);
  if (!runId) throw new Error("pending workflow start action missing");

  const selector = `[phx-click="start_workflow_run"][phx-value-run-id="${String(runId).replace(/"/g, '\\"')}"]`;
  if (!(await maybeClick(cdp, selector))) throw new Error(`could not start pending workflow ${runId}`);

  const domId = String(runId).replace(/[^A-Za-z0-9_-]/g, "-");
  await waitFor(cdp, async () => {
    const status = await evalValue(cdp, `(() => {
      const row = document.querySelector('#workflow-run-${domId}');
      return row && row.getAttribute('data-run-status');
    })()`);
    return ["completed", "failed", "blocked", "cancelled"].includes(String(status || ""));
  }, timeoutMs);

  const status = await evalValue(cdp, `(() => document.querySelector('#workflow-run-${domId}').getAttribute('data-run-status'))()`);
  if (status !== "completed") throw new Error(`workflow ${runId} ended ${status}`);
  return {completed: true, run_id: runId, status};
}

async function startAndPauseWorkflowForReview(cdp, config, timeoutMs) {
  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');
  const expectedRunId = config && config.run_id ? String(config.run_id) : null;
  const startSelector = expectedRunId
    ? `[phx-click="start_workflow_run"][phx-value-run-id="${expectedRunId.replace(/"/g, '\\"')}"]`
    : '[phx-click="start_workflow_run"]';

  await waitFor(cdp, async () => {
    return !!(await evalValue(cdp, `(() => !!document.querySelector(${JSON.stringify(startSelector)}))()`));
  }, timeoutMs);

  const runId = expectedRunId || await evalValue(cdp, `(() => {
    const button = document.querySelector(${JSON.stringify(startSelector)});
    return button && button.getAttribute('phx-value-run-id');
  })()`);
  if (!runId) throw new Error("pending workflow runtime-review action missing");
  if (!(await maybeClick(cdp, startSelector))) throw new Error(`could not start workflow ${runId}`);

  const domId = String(runId).replace(/[^A-Za-z0-9_-]/g, "-");
  await waitForWorkflowStatus(cdp, domId, ["running"], timeoutMs);

  const reviewSelector = `[phx-click="request_workflow_run_review"][phx-value-run-id="${String(runId).replace(/"/g, '\\"')}"]`;
  if (!(await maybeClick(cdp, reviewSelector))) {
    throw new Error(`runtime review action missing for ${runId}`);
  }

  const status = await waitForWorkflowStatus(cdp, domId, ["review"], timeoutMs);
  await maybeClick(cdp, '[phx-click="set_workspace_tab"][phx-value-tab="chat"]');
  await waitFor(cdp, async () => {
    return !!(await evalValue(cdp, "(() => !!document.querySelector('form[phx-submit=\"review_decision\"]'))()"));
  }, timeoutMs);

  return {review_pending: true, run_id: runId, status};
}

async function awaitWorkflowRun(cdp, config, timeoutMs) {
  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');
  const runId = String(config.run_id || "");
  if (!runId) throw new Error("await_workflow_run.run_id is required");
  const statuses = Array.isArray(config.statuses) && config.statuses.length
    ? config.statuses.map(String)
    : ["completed"];
  const domId = runId.replace(/[^A-Za-z0-9_-]/g, "-");
  const status = await waitForWorkflowStatus(cdp, domId, statuses, timeoutMs);
  if (status !== "completed") throw new Error(`workflow ${runId} ended ${status}`);
  return {completed: true, run_id: runId, status};
}

async function restartFailedWorkflowChild(cdp, config, timeoutMs) {
  await maybeClick(cdp, '[phx-click="set_inspector_tab"][phx-value-tab="artifacts"]');

  const failedRunId = String(config.failed_run_id || "");
  if (!failedRunId) throw new Error("workflow_child_restart.failed_run_id is required");

  const escapedRunId = failedRunId.replace(/"/g, '\\"');
  const selector = `[phx-click="restart_workflow_child_run"][phx-value-run-id="${escapedRunId}"]`;

  await waitFor(cdp, async () => {
    return !!(await evalValue(cdp, `(() => !!document.querySelector(${JSON.stringify(selector)}))()`));
  }, timeoutMs);

  const before = await evalValue(cdp, `(() => {
    const button = document.querySelector(${JSON.stringify(selector)});
    const row = button && button.closest('[id^="workflow-run-"]');
    return row ? {id: row.id, status: row.getAttribute('data-run-status'), text: row.innerText} : null;
  })()`);

  if (!(await maybeClick(cdp, selector))) {
    throw new Error(`could not restart failed workflow child ${failedRunId}`);
  }

  await waitForBodyText(cdp, "Restarted only failed child as attempt 2", timeoutMs);

  let retry = null;
  await waitFor(cdp, async () => {
    retry = await evalValue(cdp, `(() => {
      const rows = Array.from(document.querySelectorAll('[id^="workflow-run-"]'));
      const row = rows.find((candidate) => {
        const text = String(candidate.innerText || "");
        return text.includes("attempt 2") && text.includes("retries");
      });
      return row ? {id: row.id, status: row.getAttribute('data-run-status'), text: row.innerText} : null;
    })()`);
    return retry && retry.status === "completed";
  }, timeoutMs);

  return {
    completed: true,
    failed_run_id: failedRunId,
    before,
    retry,
    retry_attempt_visible: String(retry && retry.text || "").includes("attempt 2"),
    retry_lineage_visible: String(retry && retry.text || "").includes("retries"),
  };
}

async function waitForWorkflowStatus(cdp, domId, statuses, timeoutMs) {
  await waitFor(cdp, async () => {
    const status = await evalValue(cdp, `(() => {
      const row = document.querySelector('#workflow-run-${domId}');
      return row && row.getAttribute('data-run-status');
    })()`);
    return statuses.includes(String(status || ""));
  }, timeoutMs);

  return evalValue(cdp, `(() => {
    const row = document.querySelector('#workflow-run-${domId}');
    return row && row.getAttribute('data-run-status');
  })()`);
}

async function captureInspectorTab(cdp, request) {
  const tab = request.final_inspector_tab;
  if (!tab) return { enabled: false, status: "skipped" };

  const selector = `[phx-click="set_inspector_tab"][phx-value-tab="${String(tab).replace(/[^a-z0-9_-]/gi, "")}"]`;
  const clicked = await maybeClick(cdp, selector);
  if (!clicked) {
    return { enabled: true, status: "failed", tab, reason: "inspector tab not found" };
  }

  const needle = request.inspector_text_needle;
  if (needle) {
    await waitFor(cdp, async () => {
      const text = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
      return String(text || "").includes(String(needle));
    }, request.timeout_ms || 30000);
  } else {
    await delay(250);
  }

  const html = await evalValue(cdp, "(() => document.documentElement.outerHTML)()");
  const domText = await evalValue(cdp, "(() => document.body ? document.body.innerText : '')()");
  const screenshot = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });

  fs.writeFileSync(inspectorHtmlPath, String(html || ""));
  fs.writeFileSync(inspectorDomSnapshotPath, String(domText || ""));
  fs.writeFileSync(inspectorScreenshotPath, Buffer.from(screenshot.data || "", "base64"));

  return {
    enabled: true,
    status: "ok",
    tab,
    html_path: inspectorHtmlPath,
    dom_snapshot_path: inspectorDomSnapshotPath,
    screenshot_path: inspectorScreenshotPath,
    screenshot_byte_size: fs.statSync(inspectorScreenshotPath).size,
    text_preview: String(domText || "").slice(0, 1200),
  };
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
    const sessionStatus = await selectedSessionStatus(cdp);
    if (terminalSessionStatus(sessionStatus)) {
      return {
        observed: true,
        reason: "terminal or review checkpoint observed from selected session status",
        sessionStatus,
        planEvidence: latest,
      };
    }
    if (!sessionStatus && terminalOrReviewText(latest.text_preview)) {
      return {
        observed: true,
        reason: "terminal or review checkpoint observed from plan fallback",
        sessionStatus: null,
        planEvidence: latest,
      };
    }
    await delay(250);
  }

  return {
    observed: false,
    reason: "terminal or review checkpoint not observed before timeout",
    sessionStatus: await selectedSessionStatus(cdp),
    planEvidence: latest,
  };
}

async function selectedSessionStatus(cdp) {
  return evalValue(cdp, `(() => {
    const element = document.querySelector('#selected-session-status');
    return element ? element.getAttribute('data-session-status') : null;
  })()`);
}

function terminalSessionStatus(status) {
  return ["completed", "objective_satisfied", "blocked", "failed", "cancelled", "stopped", "review"]
    .includes(String(status || "").toLowerCase());
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
