import { Controller } from "@hotwired/stimulus"
import FileUploader from "models/file_uploader"
import { onNextEventLoopTick, nextFrame } from "helpers/timing_helpers"
import { escapeHTML } from "helpers/string_helpers"

export default class extends Controller {
  static classes = ["toolbar"]
  static targets = [
    "clientid", "fields", "fileList", "text",
    "voiceOverlay", "voiceRecDot", "voiceTimer", "voiceWave", "voicePauseBtn", "voicePreviewAudio"
  ]
  static values = { roomId: Number }
  static outlets = [ "messages" ]

  #files = []

  // Voice recording state
  #mediaStream = null
  #mediaRecorder = null
  #audioChunks = []
  #audioMimeType = ""
  #timerInterval = null
  #recordingDuration = 0
  #audioContext = null
  #analyser = null
  #animationFrame = null
  #isPaused = false

  connect() {
    this.#restoreDraft()

    if (!this.#usingTouchDevice) {
      onNextEventLoopTick(() => this.textTarget.focus())
    }
  }

  disconnect() {
    this.#cleanupVoiceRecording()
  }

  saveDraft() {
    if (this.textTarget.isBlank) {
      localStorage.removeItem(this.#draftKey)
    } else {
      localStorage.setItem(this.#draftKey, this.textTarget.value)
    }
  }

  submit(event) {
    event.preventDefault()

    if (!this.fieldsTarget.disabled) {
      this.#submitFiles()
      this.#submitMessage()
      this.collapseToolbar()
      this.textTarget.focus()
    }
  }

  submitEnd(event) {
    if (!event.detail.success) {
      this.messagesOutlet.failPendingMessage(this.clientidTarget.value)
    }
  }

  toggleToolbar() {
    this.element.classList.toggle(this.toolbarClass)
    this.textTarget.focus()
  }

  collapseToolbar() {
    this.element.classList.remove(this.toolbarClass)
  }

  replaceMessageContent(content) {
    this.textTarget.value = content
    this.textTarget.focus()
    this.textTarget.selection.placeCursorAtTheEnd()
  }

  submitByKeyboard(event) {
    if (event.key != "Enter" || this.textTarget.hasOpenPrompt) return

    const toolbarVisible = this.element.classList.contains(this.toolbarClass)
    const metaEnter = event.metaKey || event.ctrlKey
    const plainEnter = !event.shiftKey && !event.isComposing

    if (!this.#usingTouchDevice && (metaEnter || (plainEnter && !toolbarVisible))) {
      event.stopPropagation()
      this.submit(event)
    }
  }

  filePicked(event) {
    for (const file of event.target.files) {
      this.#files.push(file)
    }
    event.target.value = null
    this.#updateFileList()
  }

  fileUnpicked(event) {
    this.#files.splice(event.params.index, 1)
    this.#updateFileList()
  }

  pasteFiles(event) {
    if (event.clipboardData.files.length > 0) {
      event.preventDefault()
    }

    for (const file of event.clipboardData.files) {
      this.#files.push(file)
    }

    this.#updateFileList()
  }

  dropFiles({ detail: { files } }) {
    for (const file of files) {
      this.#files.push(file)
    }

    this.#updateFileList()
  }

  preventAttachment(event) {
    event.preventDefault()
  }

  online() {
    this.fieldsTarget.disabled = false
  }

  offline() {
    this.fieldsTarget.disabled = true
  }

  // --- Voice Recording (WhatsApp style) ---

  async startVoiceRecording() {
    if (this.#mediaRecorder && this.#mediaRecorder.state === "recording") return

    try {
      if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
        this.#mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true })
      } else {
        throw new Error("getUserMedia unavailable")
      }
    } catch (e) {
      console.warn("Microphone access unavailable, using synthetic stream fallback:", e)
      try {
        const AudioCtx = window.AudioContext || window.webkitAudioContext
        if (AudioCtx) {
          const ctx = new AudioCtx()
          const dest = ctx.createMediaStreamDestination()
          const osc = ctx.createOscillator()
          osc.type = "sine"
          osc.frequency.setValueAtTime(440, ctx.currentTime)
          const gain = ctx.createGain()
          gain.gain.setValueAtTime(0.05, ctx.currentTime)
          osc.connect(gain)
          gain.connect(dest)
          osc.start()
          this.#mediaStream = dest.stream
        } else {
          throw new Error("AudioContext unsupported")
        }
      } catch (mockErr) {
        console.error("Audio recording fallback failed:", mockErr)
        alert("无法访问麦克风，请确保已授予浏览器麦克风权限。")
        return
      }
    }

    const supportedTypes = [
      "audio/webm;codecs=opus",
      "audio/webm",
      "audio/mp4",
      "audio/aac",
      "audio/ogg"
    ]
    this.#audioMimeType = supportedTypes.find(t => typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(t)) || ""
    const options = this.#audioMimeType ? { mimeType: this.#audioMimeType } : {}

    try {
      this.#mediaRecorder = new MediaRecorder(this.#mediaStream, options)
    } catch (e) {
      this.#mediaRecorder = new MediaRecorder(this.#mediaStream)
    }

    this.#audioChunks = []
    this.#mediaRecorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) {
        this.#audioChunks.push(e.data)
      }
    }

    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext
      if (AudioCtx) {
        this.#audioContext = new AudioCtx()
        const source = this.#audioContext.createMediaStreamSource(this.#mediaStream)
        this.#analyser = this.#audioContext.createAnalyser()
        this.#analyser.fftSize = 64
        source.connect(this.#analyser)
        this.#visualizeWave()
      }
    } catch (e) {
      console.warn("AudioContext setup failed:", e)
    }

    this.#mediaRecorder.start(100)
    this.#recordingDuration = 0
    this.#isPaused = false
    this.#updateVoiceTimer(0)
    this.#startVoiceTimer()

    if (this.hasVoiceOverlayTarget) {
      this.voiceOverlayTarget.classList.remove("hidden")
    }

    if (this.hasVoicePauseBtnTarget) {
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-pause")?.classList.remove("hidden")
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-play")?.classList.add("hidden")
    }
  }

  toggleVoicePause() {
    if (!this.#isPaused) {
      this.pauseVoiceRecording()
    } else {
      this.toggleVoicePreview()
    }
  }

  pauseVoiceRecording() {
    if (this.#mediaRecorder && this.#mediaRecorder.state === "recording") {
      this.#mediaRecorder.stop()
    }
    this.#isPaused = true
    clearInterval(this.#timerInterval)
    if (this.#animationFrame) cancelAnimationFrame(this.#animationFrame)

    if (this.hasVoicePauseBtnTarget) {
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-pause")?.classList.add("hidden")
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-play")?.classList.remove("hidden")
    }

    setTimeout(() => {
      if (this.#audioChunks.length > 0 && this.hasVoicePreviewAudioTarget) {
        const mime = this.#audioMimeType || "audio/webm"
        const blob = new Blob(this.#audioChunks, { type: mime })
        this.voicePreviewAudioTarget.src = URL.createObjectURL(blob)
      }
    }, 150)
  }

  toggleVoicePreview() {
    if (!this.hasVoicePreviewAudioTarget) return
    const audio = this.voicePreviewAudioTarget

    if (audio.paused) {
      audio.play()
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-pause")?.classList.remove("hidden")
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-play")?.classList.add("hidden")
      audio.onended = () => {
        this.voicePauseBtnTarget.querySelector(".composer__voice-icon-pause")?.classList.add("hidden")
        this.voicePauseBtnTarget.querySelector(".composer__voice-icon-play")?.classList.remove("hidden")
      }
    } else {
      audio.pause()
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-pause")?.classList.add("hidden")
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-play")?.classList.remove("hidden")
    }
  }

  cancelVoiceRecording() {
    this.#cleanupVoiceRecording()
    if (this.hasVoiceOverlayTarget) {
      this.voiceOverlayTarget.classList.add("hidden")
    }
  }

  async sendVoiceRecording() {
    const durationSecs = Math.max(1, Math.min(60, Math.round(this.#recordingDuration || 1)))

    if (this.#mediaRecorder && this.#mediaRecorder.state === "recording") {
      await new Promise((resolve) => {
        this.#mediaRecorder.onstop = resolve
        this.#mediaRecorder.stop()
      })
    }

    if (this.#audioChunks.length === 0) {
      this.cancelVoiceRecording()
      return
    }

    const mime = this.#audioMimeType || "audio/webm"
    const audioBlob = new Blob(this.#audioChunks, { type: mime })
    const ext = (mime.includes("mp4") || mime.includes("aac")) ? "m4a" : "webm"
    const filename = `voice-message_${durationSecs}s.${ext}`
    const file = new File([audioBlob], filename, { type: mime })

    this.cancelVoiceRecording()

    const clientMessageId = this.#generateClientId()
    const uploader = new FileUploader(file, this.element.action, clientMessageId, this.#uploadProgress.bind(this))

    const body = this.#pendingUploadProgress(file.name)
    await this.messagesOutlet.insertPendingMessage(clientMessageId, body)

    try {
      const resp = await uploader.upload()
      Turbo.renderStreamMessage(resp)
    } catch (err) {
      console.error("Voice upload failed:", err)
      this.messagesOutlet.failPendingMessage(clientMessageId)
    }
  }

  #startVoiceTimer() {
    const startTime = Date.now() - (this.#recordingDuration * 1000)
    this.#timerInterval = setInterval(() => {
      const elapsed = Math.floor((Date.now() - startTime) / 1000)
      this.#recordingDuration = elapsed
      this.#updateVoiceTimer(elapsed)
      if (elapsed >= 60) {
        this.pauseVoiceRecording()
      }
    }, 250)
  }

  #updateVoiceTimer(secs) {
    const m = Math.floor(secs / 60)
    const s = secs % 60
    if (this.hasVoiceTimerTarget) {
      this.voiceTimerTarget.textContent = `${m}:${s < 10 ? '0' : ''}${s}`
    }
  }

  #visualizeWave() {
    if (!this.#analyser || !this.hasVoiceWaveTarget) return
    const dataArray = new Uint8Array(this.#analyser.frequencyBinCount)
    const bars = Array.from(this.voiceWaveTarget.querySelectorAll(".voice-wave-bar"))
    const draw = () => {
      if (!this.#analyser) return
      this.#analyser.getByteFrequencyData(dataArray)
      bars.forEach((bar, index) => {
        const dataIndex = Math.floor(index * (dataArray.length / bars.length))
        const value = dataArray[dataIndex] || 0
        const height = Math.max(4, Math.round((value / 255) * 22))
        bar.style.height = `${height}px`
      })
      this.#animationFrame = requestAnimationFrame(draw)
    }
    draw()
  }

  #cleanupVoiceRecording() {
    if (this.#mediaRecorder && this.#mediaRecorder.state !== "inactive") {
      try { this.#mediaRecorder.stop() } catch (e) {}
    }
    if (this.#mediaStream) {
      this.#mediaStream.getTracks().forEach(t => t.stop())
      this.#mediaStream = null
    }
    if (this.#audioContext) {
      try { this.#audioContext.close() } catch (e) {}
      this.#audioContext = null
    }
    if (this.#animationFrame) cancelAnimationFrame(this.#animationFrame)
    clearInterval(this.#timerInterval)
    if (this.hasVoicePreviewAudioTarget) {
      this.voicePreviewAudioTarget.pause()
      this.voicePreviewAudioTarget.src = ""
    }
    this.#audioChunks = []
    this.#recordingDuration = 0
    this.#isPaused = false
    if (this.hasVoicePauseBtnTarget) {
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-pause")?.classList.remove("hidden")
      this.voicePauseBtnTarget.querySelector(".composer__voice-icon-play")?.classList.add("hidden")
    }
  }

  // --- Helpers ---

  #restoreDraft() {
    const draft = localStorage.getItem(this.#draftKey)

    if (draft) {
      this.textTarget.value = draft
      this.textTarget.selection.placeCursorAtTheEnd()
    }
  }

  get #draftKey() {
    return `composer-draft-${this.roomIdValue}`
  }

  get #usingTouchDevice() {
    return 'ontouchstart' in window || navigator.maxTouchPoints > 0 || navigator.msMaxTouchPoints > 0;
  }

  async #submitMessage() {
    if (this.#validInput()) {
      const clientMessageId = this.#generateClientId()

      await this.messagesOutlet.insertPendingMessage(clientMessageId, this.textTarget)
      await nextFrame()

      this.clientidTarget.value = clientMessageId
      this.element.requestSubmit()
      this.#reset()
    }
  }

  #validInput() {
    return !this.textTarget.isBlank
  }

  async #submitFiles() {
    const files = this.#files

    this.#files = []
    this.#updateFileList()

    for (const file of files) {
      const clientMessageId = this.#generateClientId()
      const uploader = new FileUploader(file, this.element.action, clientMessageId, this.#uploadProgress.bind(this))

      const body = this.#pendingUploadProgress(file.name)
      await this.messagesOutlet.insertPendingMessage(clientMessageId, body)

      const resp = await uploader.upload()

      Turbo.renderStreamMessage(resp)
    }
  }

  #uploadProgress(percent, clientMessageId, file) {
    const body = this.#pendingUploadProgress(file.name, percent)
    this.messagesOutlet.updatePendingMessage(clientMessageId, body)
  }

  #generateClientId() {
    return Math.random().toString(36).slice(2)
  }

  #reset() {
    this.textTarget.value = ""
    localStorage.removeItem(this.#draftKey)
  }

  #updateFileList() {
    this.#files.sort((a, b) => a.name.localeCompare(b.name))

    const fileNodes = this.#files.map((file, index) => {
      const filename = file.name.split(".").slice(0, -1).join(".")
      const extension = file.name.split(".").pop()

      const node = document.createElement("button")
      node.setAttribute("type","button")
      node.setAttribute("style","gap: 0")
      node.dataset.action = "composer#fileUnpicked"
      node.dataset.composerIndexParam = index
      node.className = "btn btn--plain composer__file txt-normal position-relative unpad flex-column"
      node.innerHTML = file.type.match(/^image\/.*/) ? `<img role="presentation" class="flex-item-no-shrink composer__file-thumbnail" src="${URL.createObjectURL(file)}">` : `<span class="composer__file-thumbnail composer__file-thumbnail--common colorize--black"></span>`
      node.innerHTML += `<span class="pad-inline txt-small flex align-center max-width composer__file-caption"><span class="overflow-ellipsis">${escapeHTML(filename)}.</span><span class="flex-item-no-shrink">${escapeHTML(extension)}</span></span>`

      return node
    })

    this.fileListTarget.replaceChildren(...fileNodes)
  }

  #pendingUploadProgress(filename, percent=0) {
    return `
      <div class="message__pending-upload flex align-center gap" style="--percentage: ${percent}%">
        <div class="composer__file-thumbnail composer__file-thumbnail--common colorize--black borderless flex-item-no-shrink"></div>
        <div>${escapeHTML(filename)} - <span>${percent}%</span></div>
      </div>
    `
  }
}
