import { Controller } from "@hotwired/stimulus"
import { get } from "@rails/request.js"
import { cable } from "@hotwired/turbo-rails"
import { pageIsTurboPreview } from "helpers/turbo_helpers"

const OFFLINE_AFTER_DISCONNECTED_TIMEOUT = 5_000
const REFRESH_AFTER_HIDDEN_TIMEOUT = 60_000

export default class extends Controller {
  static targets = ["message"]
  static values = { loadedAt: Number, url: String }

  #lastLoadedAt
  #offlineTimer = null
  #hiddenAt = null
  #savedMessages = null
  #isOffline = false
  #onNativeOffline = null
  #onNativeOnline = null
  #onBeforeFetchResponse = null

  async connect() {
    if (!pageIsTurboPreview()) {
      this.#lastLoadedAt = this.loadedAtValue

      this.#onNativeOffline = () => this.#handleOffline()
      window.addEventListener("offline", this.#onNativeOffline)

      this.#onNativeOnline = () => this.online()
      window.addEventListener("online", this.#onNativeOnline)

      this.#onBeforeFetchResponse = (event) => {
        const fetchResponse = event.detail?.fetchResponse
        const responseUrl = fetchResponse?.response?.url || ""
        if (
          fetchResponse?.statusCode === 401 ||
          fetchResponse?.statusCode === 302 ||
          responseUrl.includes("/session/new")
        ) {
          this.#savedMessages = null
          window.location.href = "/session/new"
        }
      }
      window.addEventListener("turbo:before-fetch-response", this.#onBeforeFetchResponse)

      if (typeof navigator !== "undefined" && navigator.onLine === false) {
        this.#handleOffline()
      } else {
        this.#channelDisconnected()
      }

      this.channel = await cable.subscribeTo({ channel: "HeartbeatChannel" }, {
        connected: this.#channelConnected.bind(this),
        disconnected: this.#channelDisconnected.bind(this)
      })
    }
  }

  disconnect() {
    this.channel?.unsubscribe()
    if (this.#onNativeOffline) {
      window.removeEventListener("offline", this.#onNativeOffline)
      this.#onNativeOffline = null
    }
    if (this.#onNativeOnline) {
      window.removeEventListener("online", this.#onNativeOnline)
      this.#onNativeOnline = null
    }
    if (this.#onBeforeFetchResponse) {
      window.removeEventListener("turbo:before-fetch-response", this.#onBeforeFetchResponse)
      this.#onBeforeFetchResponse = null
    }
    clearTimeout(this.#offlineTimer)
  }

  messageTargetConnected(target) {
    this.#lastLoadedAt = Math.max(this.#lastLoadedAt, target.dataset.messageUpdatedAt || 0)
  }

  visibilityChanged() {
    if (document.visibilityState === "visible") {
      if (this.#hiddenForTooLong()) {
        this.#refresh("visibility")
        this.dispatch("visible")
      }
      this.#hiddenAt = null
    } else {
      this.#hiddenAt = Date.now()
    }
  }

  online() {
    // Trigger reconnection attempt whenever the browser comes back from being offline
    this.channel?.consumer?.connection?.monitor?.visibilityDidChange()
    this.#refresh("connection")
  }

  offline() {
    this.#handleOffline()
  }

  #channelConnected() {
    clearTimeout(this.#offlineTimer)
    this.#refresh("connection")
  }

  #channelDisconnected(event) {
    if (event && event.willAttemptReconnect === false) {
      // Server explicitly terminated the connection (e.g. password changed or user locked/banned)
      this.#savedMessages = null
      window.location.href = "/session/new"
      return
    }

    clearTimeout(this.#offlineTimer)
    this.#offlineTimer = setTimeout(() => {
      this.#handleOffline()
    }, OFFLINE_AFTER_DISCONNECTED_TIMEOUT)
  }

  #handleOffline() {
    if (this.#isOffline) return
    this.#isOffline = true

    this.dispatch("offline", { target: window })

    // Security: Clear all message elements from the DOM and hold them in memory
    if (!this.#savedMessages) {
      this.#savedMessages = document.createDocumentFragment()
      while (this.element.firstChild) {
        this.#savedMessages.appendChild(this.element.firstChild)
      }

      const placeholder = document.createElement("div")
      placeholder.id = "room-offline-security-placeholder"
      placeholder.className = "room-offline-notice"
      placeholder.innerHTML = `
        <div class="room-offline-card">
          <div class="room-offline-icon">⚠️</div>
          <div class="room-offline-title">网络连接已断开</div>
          <div class="room-offline-desc">正在等待网络恢复...</div>
        </div>
      `
      this.element.appendChild(placeholder)
    }
  }

  #restoreMessagesIfOffline() {
    if (!this.#isOffline && !this.#savedMessages) return

    const placeholder = this.element.querySelector("#room-offline-security-placeholder")
    if (placeholder) {
      placeholder.remove()
    }

    if (this.#savedMessages) {
      this.element.appendChild(this.#savedMessages)
      this.#savedMessages = null
    }

    this.#isOffline = false
    this.dispatch("online", { target: window })
  }

  async #refresh(reason) {
    try {
      const response = await get(this.urlValue, { query: { since: this.#lastLoadedAt, reason: reason }, responseKind: "turbo-stream" })
      if (!response) return

      const responseUrl = response.response?.url || ""
      if (
        response.unauthenticated ||
        response.statusCode === 401 ||
        response.statusCode === 302 ||
        response.redirected ||
        responseUrl.includes("/session/new")
      ) {
        this.#savedMessages = null
        window.location.href = "/session/new"
        return
      }

      if (response.ok) {
        this.#restoreMessagesIfOffline()
      }
    } catch (e) {
      // Still offline or request failed
    }
  }

  #hiddenForTooLong() {
    return this.#hiddenAt && Date.now() - this.#hiddenAt > REFRESH_AFTER_HIDDEN_TIMEOUT
  }
}
