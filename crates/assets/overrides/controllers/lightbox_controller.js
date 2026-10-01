import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "image", "dialog", "zoomedImage", "download", "share" ]

  connect() {
    this.scale = 1
    this.translateX = 0
    this.translateY = 0
    this.isDragging = false
    this.isPinching = false
    this.lastTapTime = 0

    if (this.hasDialogTarget) {
      this.dialogTarget.addEventListener("wheel", this.#onWheel, { passive: false })
      this.dialogTarget.addEventListener("click", this.#onDialogClick)
      this.dialogTarget.addEventListener("touchstart", this.#onTouchStart, { passive: false })
      this.dialogTarget.addEventListener("touchmove", this.#onTouchMove, { passive: false })
      this.dialogTarget.addEventListener("touchend", this.#onTouchEnd)
      this.dialogTarget.addEventListener("touchcancel", this.#onTouchEnd)
    }

    if (this.hasZoomedImageTarget) {
      this.zoomedImageTarget.draggable = false
      this.zoomedImageTarget.style.touchAction = "none"
      this.zoomedImageTarget.style.userSelect = "none"
      this.zoomedImageTarget.style.webkitUserSelect = "none"
      this.zoomedImageTarget.style.cursor = "zoom-in"
      this.zoomedImageTarget.addEventListener("mousedown", this.#onMouseDown)
      this.zoomedImageTarget.addEventListener("dblclick", this.#onDblClick)
    }

    window.addEventListener("mousemove", this.#onMouseMove)
    window.addEventListener("mouseup", this.#onMouseUp)
  }

  disconnect() {
    if (this.hasDialogTarget) {
      this.dialogTarget.removeEventListener("wheel", this.#onWheel)
      this.dialogTarget.removeEventListener("click", this.#onDialogClick)
      this.dialogTarget.removeEventListener("touchstart", this.#onTouchStart)
      this.dialogTarget.removeEventListener("touchmove", this.#onTouchMove)
      this.dialogTarget.removeEventListener("touchend", this.#onTouchEnd)
      this.dialogTarget.removeEventListener("touchcancel", this.#onTouchEnd)
    }

    if (this.hasZoomedImageTarget) {
      this.zoomedImageTarget.removeEventListener("mousedown", this.#onMouseDown)
      this.zoomedImageTarget.removeEventListener("dblclick", this.#onDblClick)
    }

    window.removeEventListener("mousemove", this.#onMouseMove)
    window.removeEventListener("mouseup", this.#onMouseUp)
  }

  open(event) {
    event.preventDefault()

    this.#resetTransform(false)
    this.dialogTarget.showModal()
    this.#set(event.target.closest("a"))
  }

  reset() {
    this.#resetTransform(false)
    this.zoomedImageTarget.src = ""
    this.downloadTarget.href = ""
    this.shareTarget.dataset.webShareFilesValue = ""
  }

  #set(target) {
    this.zoomedImageTarget.src = target.href
    this.downloadTarget.href = target.dataset.lightboxUrlValue
    this.shareTarget.dataset.webShareFilesValue = target.dataset.lightboxUrlValue
  }

  #resetTransform(animate = false) {
    this.scale = 1
    this.translateX = 0
    this.translateY = 0
    this.isDragging = false
    this.isPinching = false
    this.#applyTransform(animate)
  }

  #applyTransform(animate = false) {
    if (!this.hasZoomedImageTarget) return

    this.zoomedImageTarget.style.transition = animate
      ? "transform 0.22s cubic-bezier(0.25, 1, 0.5, 1)"
      : "none"
    this.zoomedImageTarget.style.transform = `translate3d(${this.translateX}px, ${this.translateY}px, 0) scale(${this.scale})`
    this.zoomedImageTarget.style.cursor = this.scale > 1
      ? (this.isDragging ? "grabbing" : "grab")
      : "zoom-in"
  }

  #zoomTo(newScale, clientX, clientY, animate = true) {
    const clampedScale = Math.min(Math.max(1, newScale), 5)
    if (clampedScale <= 1.01) {
      this.#resetTransform(animate)
      return
    }

    const rect = this.zoomedImageTarget.getBoundingClientRect()
    const mouseX = clientX - (rect.left + rect.width / 2)
    const mouseY = clientY - (rect.top + rect.height / 2)
    const ratio = clampedScale / this.scale - 1

    this.translateX -= mouseX * ratio
    this.translateY -= mouseY * ratio
    this.scale = clampedScale

    this.#clampTranslation()
    this.#applyTransform(animate)
  }

  #clampTranslation() {
    if (!this.hasDialogTarget || !this.hasZoomedImageTarget || this.scale <= 1) {
      this.translateX = 0
      this.translateY = 0
      return
    }

    const dialogRect = this.dialogTarget.getBoundingClientRect()
    const imgW = (this.zoomedImageTarget.offsetWidth || 1) * this.scale
    const imgH = (this.zoomedImageTarget.offsetHeight || 1) * this.scale

    const maxPanX = Math.max(0, (imgW - dialogRect.width) / 2 + 80)
    const maxPanY = Math.max(0, (imgH - dialogRect.height) / 2 + 80)

    this.translateX = Math.min(Math.max(this.translateX, -maxPanX), maxPanX)
    this.translateY = Math.min(Math.max(this.translateY, -maxPanY), maxPanY)
  }

  #onWheel = (e) => {
    if (!this.dialogTarget.open) return
    e.preventDefault()

    const zoomFactor = e.deltaY < 0 ? 1.15 : 0.87
    const newScale = Math.min(Math.max(1, this.scale * zoomFactor), 5)

    if (newScale <= 1.01) {
      this.#resetTransform(false)
    } else {
      const rect = this.zoomedImageTarget.getBoundingClientRect()
      const mouseX = e.clientX - (rect.left + rect.width / 2)
      const mouseY = e.clientY - (rect.top + rect.height / 2)
      const ratio = newScale / this.scale - 1

      this.translateX -= mouseX * ratio
      this.translateY -= mouseY * ratio
      this.scale = newScale

      this.#clampTranslation()
      this.#applyTransform(false)
    }
  }

  #onMouseDown = (e) => {
    if (!this.dialogTarget.open || e.button !== 0) return
    if (e.target !== this.zoomedImageTarget) return

    e.preventDefault()

    if (this.scale > 1) {
      this.isDragging = true
      this.dragStartX = e.clientX
      this.dragStartY = e.clientY
      this.#applyTransform(false)
    }
  }

  #onMouseMove = (e) => {
    if (!this.isDragging || !this.dialogTarget.open || this.scale <= 1) return
    e.preventDefault()

    const dx = e.clientX - this.dragStartX
    const dy = e.clientY - this.dragStartY
    this.dragStartX = e.clientX
    this.dragStartY = e.clientY

    this.translateX += dx
    this.translateY += dy

    this.#clampTranslation()
    this.#applyTransform(false)
  }

  #onMouseUp = () => {
    if (this.isDragging) {
      this.isDragging = false
      this.#applyTransform(false)
    }
  }

  #onDblClick = (e) => {
    if (!this.dialogTarget.open || e.target !== this.zoomedImageTarget) return
    e.preventDefault()

    if (this.scale > 1.05) {
      this.#resetTransform(true)
    } else {
      this.#zoomTo(2.5, e.clientX, e.clientY, true)
    }
  }

  #onTouchStart = (e) => {
    if (!this.dialogTarget.open) return
    if (e.target !== this.zoomedImageTarget) return

    if (e.touches.length === 2) {
      e.preventDefault()
      this.isPinching = true
      this.isDragging = false
      this.pinchStartDistance = Math.hypot(
        e.touches[0].clientX - e.touches[1].clientX,
        e.touches[0].clientY - e.touches[1].clientY
      )
      this.pinchStartScale = this.scale
      this.pinchMidX = (e.touches[0].clientX + e.touches[1].clientX) / 2
      this.pinchMidY = (e.touches[0].clientY + e.touches[1].clientY) / 2
    } else if (e.touches.length === 1) {
      const now = Date.now()
      if (now - this.lastTapTime < 300) {
        e.preventDefault()
        if (this.scale > 1.05) {
          this.#resetTransform(true)
        } else {
          this.#zoomTo(2.5, e.touches[0].clientX, e.touches[0].clientY, true)
        }
        this.lastTapTime = 0
        return
      }
      this.lastTapTime = now

      if (this.scale > 1) {
        this.isDragging = true
        this.touchStartX = e.touches[0].clientX
        this.touchStartY = e.touches[0].clientY
      }
    }
  }

  #onTouchMove = (e) => {
    if (!this.dialogTarget.open) return

    if (e.touches.length === 2 && this.isPinching) {
      e.preventDefault()
      const distance = Math.hypot(
        e.touches[0].clientX - e.touches[1].clientX,
        e.touches[0].clientY - e.touches[1].clientY
      )
      if (this.pinchStartDistance > 0) {
        const scaleRatio = distance / this.pinchStartDistance
        const newScale = Math.min(Math.max(1, this.pinchStartScale * scaleRatio), 5)

        const midX = (e.touches[0].clientX + e.touches[1].clientX) / 2
        const midY = (e.touches[0].clientY + e.touches[1].clientY) / 2

        const rect = this.zoomedImageTarget.getBoundingClientRect()
        const centerX = rect.left + rect.width / 2
        const centerY = rect.top + rect.height / 2
        const ratio = newScale / this.scale - 1

        this.translateX -= (midX - centerX) * ratio
        this.translateY -= (midY - centerY) * ratio

        this.translateX += (midX - this.pinchMidX)
        this.translateY += (midY - this.pinchMidY)

        this.pinchMidX = midX
        this.pinchMidY = midY
        this.scale = newScale

        this.#clampTranslation()
        this.#applyTransform(false)
      }
    } else if (e.touches.length === 1 && this.isDragging && this.scale > 1) {
      e.preventDefault()
      const dx = e.touches[0].clientX - this.touchStartX
      const dy = e.touches[0].clientY - this.touchStartY
      this.touchStartX = e.touches[0].clientX
      this.touchStartY = e.touches[0].clientY

      this.translateX += dx
      this.translateY += dy

      this.#clampTranslation()
      this.#applyTransform(false)
    }
  }

  #onTouchEnd = (e) => {
    if (e.touches.length === 0) {
      this.isPinching = false
      this.isDragging = false
      if (this.scale < 1.05) {
        this.#resetTransform(true)
      } else {
        this.#clampTranslation()
        this.#applyTransform(true)
      }
    } else if (e.touches.length === 1) {
      this.isPinching = false
      if (this.scale > 1) {
        this.isDragging = true
        this.touchStartX = e.touches[0].clientX
        this.touchStartY = e.touches[0].clientY
      }
    }
  }

  #onDialogClick = (e) => {
    if (e.target === this.dialogTarget) {
      this.dialogTarget.close()
    }
  }
}
