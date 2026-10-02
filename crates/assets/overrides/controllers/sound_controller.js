import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { "url": String }
  static targets = [ "audio", "unreadDot", "bubble" ]

  connect() {
    this.#checkReadStatus()
  }

  play() {
    if (this.hasAudioTarget) {
      this.togglePlay()
    } else {
      const sound = new Audio(this.urlValue)
      sound.play()
    }
  }

  pause() {
    if (this.hasAudioTarget && !this.audioTarget.paused) {
      this.audioTarget.pause()
    }
  }

  togglePlay(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    if (!this.hasAudioTarget) {
      this.play()
      return
    }

    if (!this.audioTarget.paused) {
      this.audioTarget.pause()
    } else {
      // Stop other playing voice messages in the room
      if (window.__activeSoundPlayer && window.__activeSoundPlayer !== this) {
        window.__activeSoundPlayer.pause()
      }

      this.markAsRead()
      this.audioTarget.play().catch(e => console.warn("Audio play prevented:", e))
      window.__activeSoundPlayer = this
    }
  }

  onPlay() {
    if (this.hasBubbleTarget) {
      this.bubbleTarget.classList.add("voice-bubble--playing")
    }
    window.__activeSoundPlayer = this
  }

  onPause() {
    if (this.hasBubbleTarget) {
      this.bubbleTarget.classList.remove("voice-bubble--playing")
    }
    if (window.__activeSoundPlayer === this) {
      window.__activeSoundPlayer = null
    }
  }

  onEnded() {
    if (this.hasBubbleTarget) {
      this.bubbleTarget.classList.remove("voice-bubble--playing")
    }
    if (window.__activeSoundPlayer === this) {
      window.__activeSoundPlayer = null
    }

    this.#autoPlayNext()
  }

  markAsRead() {
    const messageId = this.#messageId
    if (messageId) {
      try {
        localStorage.setItem(`voice-read-${messageId}`, "1")
      } catch (e) {}
    }
    if (this.hasUnreadDotTarget) {
      this.unreadDotTarget.classList.add("hidden")
    }
  }

  #checkReadStatus() {
    const messageEl = this.element.closest(".message")
    const authorId = messageEl?.dataset.userId
    const currentUserId = window.Current?.user?.id

    // Own messages never show the unread dot
    const isOwn = currentUserId && authorId && String(currentUserId) === String(authorId)
    if (isOwn) {
      if (this.hasUnreadDotTarget) this.unreadDotTarget.classList.add("hidden")
      return
    }

    const messageId = this.#messageId
    if (messageId && localStorage.getItem(`voice-read-${messageId}`)) {
      if (this.hasUnreadDotTarget) this.unreadDotTarget.classList.add("hidden")
    }
  }

  #autoPlayNext() {
    const allVoiceElements = Array.from(document.querySelectorAll(".voice-message-container[data-controller~='sound']"))
    const currentIndex = allVoiceElements.indexOf(this.element)
    if (currentIndex === -1) return

    for (let i = currentIndex + 1; i < allVoiceElements.length; i++) {
      const nextEl = allVoiceElements[i]
      const nextMsg = nextEl.closest(".message")
      const nextMsgId = nextMsg?.dataset.messageId

      // Find the next message not yet marked as read in localStorage
      if (nextMsgId && !localStorage.getItem(`voice-read-${nextMsgId}`)) {
        const nextCtrl = this.application.getControllerForElementAndIdentifier(nextEl, "sound")
        if (nextCtrl) {
          nextCtrl.togglePlay()
          break
        }
      }
    }
  }

  get #messageId() {
    return this.element.closest(".message")?.dataset.messageId
  }
}
