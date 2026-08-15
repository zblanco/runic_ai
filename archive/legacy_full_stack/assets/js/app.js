// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/runic_ai"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const WORKBENCH_PREFS_KEY = "runic-ai-workbench-preferences"
const Hooks = {
  WorkbenchPreferences: {
    mounted() {
      this.keyBuffer = ""
      this.restorePreferences()
      this.handleKeydown = event => this.onKeydown(event)
      window.addEventListener("keydown", this.handleKeydown)
    },
    updated() {
      this.persistPreferences()
    },
    destroyed() {
      window.removeEventListener("keydown", this.handleKeydown)
    },
    restorePreferences() {
      try {
        const prefs = JSON.parse(localStorage.getItem(WORKBENCH_PREFS_KEY) || "{}")
        this.pushEvent("restore_preferences", {
          pinned_session_ids: prefs.pinned_session_ids || [],
          bookmarked_artifact_ids: prefs.bookmarked_artifact_ids || [],
          contrast_mode: prefs.contrast_mode || "normal",
          motion_mode: prefs.motion_mode || "full",
        })
      } catch (_error) {
        localStorage.removeItem(WORKBENCH_PREFS_KEY)
      }
    },
    persistPreferences() {
      const prefs = {
        pinned_session_ids: readJsonData(this.el.dataset.pinnedSessionIds, []),
        bookmarked_artifact_ids: readJsonData(this.el.dataset.bookmarkedArtifactIds, []),
        contrast_mode: this.el.dataset.contrast || "normal",
        motion_mode: this.el.dataset.motion || "full",
      }
      localStorage.setItem(WORKBENCH_PREFS_KEY, JSON.stringify(prefs))
    },
    onKeydown(event) {
      if (event.defaultPrevented) return

      const target = event.target
      const typing = target?.matches?.("input, textarea, select, [contenteditable='true']")

      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        this.pushEvent("toggle_command_palette", {})
        return
      }

      if (event.key === "Escape") {
        this.pushEvent("close_command_palette", {})
        return
      }

      if (typing) return

      if (event.key === "/") {
        event.preventDefault()
        focusComposer()
        return
      }

      const key = event.key.toLowerCase()
      this.keyBuffer = (this.keyBuffer + key).slice(-2)

      if (this.keyBuffer === "gn") {
        event.preventDefault()
        this.pushEvent("run_command", {action: "new_session"})
        this.keyBuffer = ""
      } else if (this.keyBuffer === "gr") {
        event.preventDefault()
        this.pushEvent("run_command", {action: "reviews"})
        this.keyBuffer = ""
      } else if (this.keyBuffer === "gl") {
        event.preventDefault()
        this.pushEvent("run_command", {action: "logs"})
        this.keyBuffer = ""
      }
    },
  },
  WorkbenchScroll: {
    mounted() {
      this.shouldStick = true
      this.el.addEventListener("scroll", () => {
        const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
        this.shouldStick = distance < 96
      })
      this.scrollToBottom()
    },
    beforeUpdate() {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.shouldStick = distance < 96
    },
    updated() {
      if (this.shouldStick) this.scrollToBottom()
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    },
  },
  MermaidGraph: {
    mounted() {
      this.renderGraph()
    },
    updated() {
      this.renderGraph()
    },
    async renderGraph() {
      const sourceEl = this.el.querySelector("[data-graph-source]")
      const outputEl = this.el.querySelector(".runic-mermaid-output")
      const statusEl = this.el.querySelector(".runic-mermaid-status")
      const source = sourceEl?.textContent || ""
      const renderSource = source.replace(/\\n/g, "<br/>")

      if (!source || !outputEl || !statusEl) return

      try {
        await ensureMermaid()
        const graphId = "runic-ai-web-graph-" + (this.el.dataset.graphHash || Date.now())
        document.getElementById("d" + graphId)?.remove()
        const {svg, bindFunctions} = await window.mermaid.render(graphId, renderSource)
        outputEl.innerHTML = svg
        bindFunctions?.(outputEl)
        statusEl.textContent = "Rendered with Mermaid dark theme"
        statusEl.dataset.status = "ok"
      } catch (error) {
        const graphId = "runic-ai-web-graph-" + (this.el.dataset.graphHash || "")
        document.getElementById("d" + graphId)?.remove()
        outputEl.innerHTML = ""
        statusEl.textContent = "Mermaid render failed; source fallback remains visible"
        statusEl.dataset.status = "error"
        console.warn("RunicAI Mermaid render failed", error)
      }
    },
  },
  GraphCopy: {
    mounted() {
      this.el.addEventListener("click", async event => {
        event.preventDefault()
        const target = document.querySelector(this.el.dataset.copySelector)
        const text = target?.hasAttribute("data-graph-source") ? target.textContent : target?.outerHTML
        if (!text) return

        try {
          await navigator.clipboard.writeText(text)
          this.el.dataset.copied = "true"
          setTimeout(() => delete this.el.dataset.copied, 1200)
        } catch (_error) {
          this.el.dataset.copied = "blocked"
        }
      })
    },
  },
}

window.addEventListener("phx:focus-composer", () => focusComposer())

function focusComposer() {
  const composer = document.getElementById("run-objective")
  if (composer) {
    composer.focus({preventScroll: true})
    composer.setSelectionRange?.(composer.value.length, composer.value.length)
  }
}

function readJsonData(value, fallback) {
  try {
    return JSON.parse(value || JSON.stringify(fallback))
  } catch (_error) {
    return fallback
  }
}

let mermaidLoadPromise

function ensureMermaid() {
  if (window.mermaid) {
    initializeMermaid()
    return Promise.resolve(window.mermaid)
  }

  if (!mermaidLoadPromise) {
    mermaidLoadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = "https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"
      script.onload = () => {
        initializeMermaid()
        resolve(window.mermaid)
      }
      script.onerror = reject
      document.head.appendChild(script)
    })
  }

  return mermaidLoadPromise
}

function initializeMermaid() {
  if (!window.mermaid || window.runicAiMermaidInitialized) return

  window.mermaid.initialize({
    startOnLoad: false,
    theme: "dark",
    securityLevel: "strict",
    themeVariables: {
      background: "#0d0912",
      primaryColor: "#19121f",
      primaryTextColor: "#eee6d8",
      primaryBorderColor: "#876539",
      lineColor: "#d8a34c",
      secondaryColor: "#10251f",
      tertiaryColor: "#251a32",
    },
  })
  window.runicAiMermaidInitialized = true
}
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
