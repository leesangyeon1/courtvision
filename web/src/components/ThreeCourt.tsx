import { useEffect, useRef } from 'react'
import * as THREE from 'three'
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
import {
  ARC_JOIN_Y,
  CORNER_X,
  COURT_H,
  COURT_W,
  FT_CIRCLE_R,
  FT_LINE_Y,
  KEY_HALF_W,
  RIM_X,
  RIM_Y,
  THREE_R,
  distFromRim,
} from '../lib/court'
import type { EventRow } from '../types/contract'

const RIM_HEIGHT = 10 // ft
const RELEASE_HEIGHT = 6.5 // ft

/** Court plane texture drawn from the shared ft constants (20 px per ft). */
function drawCourtCanvas(): HTMLCanvasElement {
  const px = 20
  const c = document.createElement('canvas')
  c.width = COURT_W * px
  c.height = COURT_H * px
  const g = c.getContext('2d')!
  g.fillStyle = '#0d1118'
  g.fillRect(0, 0, c.width, c.height)
  g.strokeStyle = '#39485f'
  g.lineWidth = 3
  g.strokeRect(1.5, 1.5, c.width - 3, c.height - 3)
  g.strokeRect((RIM_X - KEY_HALF_W) * px, 0, KEY_HALF_W * 2 * px, FT_LINE_Y * px)
  g.beginPath()
  g.arc(RIM_X * px, FT_LINE_Y * px, FT_CIRCLE_R * px, 0, Math.PI * 2)
  g.stroke()
  g.beginPath()
  g.moveTo((RIM_X - 3) * px, 4 * px)
  g.lineTo((RIM_X + 3) * px, 4 * px)
  g.stroke()
  // 3-pt line: corner segments + 23.75 ft arc around the rim
  const a0 = Math.atan2(ARC_JOIN_Y - RIM_Y, CORNER_X - RIM_X)
  const a1 = Math.atan2(ARC_JOIN_Y - RIM_Y, COURT_W - CORNER_X - RIM_X)
  g.beginPath()
  g.moveTo(CORNER_X * px, 0)
  g.lineTo(CORNER_X * px, ARC_JOIN_Y * px)
  g.arc(RIM_X * px, RIM_Y * px, THREE_R * px, a0, a1, true)
  g.lineTo((COURT_W - CORNER_X) * px, 0)
  g.stroke()
  g.strokeStyle = '#ff7a2f'
  g.beginPath()
  g.arc(RIM_X * px, RIM_Y * px, 0.75 * px, 0, Math.PI * 2)
  g.stroke()
  return c
}

/** Deterministic parabola from the recorded release point to the rim. */
function shotArc(shot: EventRow): THREE.Line {
  const sx = shot.court_x * COURT_W
  const sz = shot.court_y * COURT_H
  const apexBoost = 3 + distFromRim(sx, sz) * 0.28 // longer shot -> higher arc
  const pts: THREE.Vector3[] = []
  const n = 28
  for (let i = 0; i <= n; i++) {
    const t = i / n
    pts.push(
      new THREE.Vector3(
        sx + (RIM_X - sx) * t,
        RELEASE_HEIGHT + (RIM_HEIGHT - RELEASE_HEIGHT) * t + apexBoost * 4 * t * (1 - t),
        sz + (RIM_Y - sz) * t,
      ),
    )
  }
  return new THREE.Line(
    new THREE.BufferGeometry().setFromPoints(pts),
    new THREE.LineBasicMaterial({
      color: shot.made ? 0x22c55e : 0xef4444,
      transparent: true,
      opacity: shot.made ? 0.9 : 0.55,
    }),
  )
}

export default function ThreeCourt({ shots }: { shots: EventRow[] }) {
  const containerRef = useRef<HTMLDivElement>(null)
  const arcsRef = useRef<THREE.Group | null>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const scene = new THREE.Scene()
    scene.background = new THREE.Color(0x06080c)

    // World mapping: court (x ft, y ft depth) -> world (x, height, z=y),
    // baseline at z=0, rim torus at (25, 10, 5.25).
    const texture = new THREE.CanvasTexture(drawCourtCanvas())
    texture.anisotropy = 4
    const plane = new THREE.Mesh(
      new THREE.PlaneGeometry(COURT_W, COURT_H),
      new THREE.MeshBasicMaterial({ map: texture }),
    )
    plane.rotation.x = -Math.PI / 2
    plane.position.set(COURT_W / 2, 0, COURT_H / 2)
    scene.add(plane)

    const rim = new THREE.Mesh(
      new THREE.TorusGeometry(0.75, 0.07, 10, 32),
      new THREE.MeshBasicMaterial({ color: 0xff7a2f }),
    )
    rim.rotation.x = -Math.PI / 2
    rim.position.set(RIM_X, RIM_HEIGHT, RIM_Y)
    scene.add(rim)

    const arcs = new THREE.Group()
    scene.add(arcs)
    arcsRef.current = arcs

    const camera = new THREE.PerspectiveCamera(
      50,
      container.clientWidth / Math.max(1, container.clientHeight),
      0.1,
      500,
    )
    camera.position.set(COURT_W / 2, 38, COURT_H + 24)

    const renderer = new THREE.WebGLRenderer({ antialias: true })
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
    renderer.setSize(container.clientWidth, container.clientHeight)
    container.appendChild(renderer.domElement)

    const controls = new OrbitControls(camera, renderer.domElement)
    controls.target.set(COURT_W / 2, 0, COURT_H / 2 - 4)
    controls.enableDamping = true
    controls.maxPolarAngle = Math.PI / 2 - 0.05

    let frame = 0
    const animate = () => {
      frame = requestAnimationFrame(animate)
      controls.update()
      renderer.render(scene, camera)
    }
    animate()

    const ro = new ResizeObserver(() => {
      camera.aspect = container.clientWidth / Math.max(1, container.clientHeight)
      camera.updateProjectionMatrix()
      renderer.setSize(container.clientWidth, container.clientHeight)
    })
    ro.observe(container)

    return () => {
      cancelAnimationFrame(frame)
      ro.disconnect()
      controls.dispose()
      arcsRef.current = null
      scene.traverse((obj) => {
        if (obj instanceof THREE.Mesh || obj instanceof THREE.Line) {
          obj.geometry.dispose()
          ;(obj.material as THREE.Material).dispose()
        }
      })
      texture.dispose()
      renderer.dispose()
      container.removeChild(renderer.domElement)
    }
  }, [])

  // Arcs update in place when shots change (no scene rebuild).
  useEffect(() => {
    const arcs = arcsRef.current
    if (!arcs) return
    while (arcs.children.length) {
      const child = arcs.children[0] as THREE.Line
      arcs.remove(child)
      child.geometry.dispose()
      ;(child.material as THREE.Material).dispose()
    }
    shots.forEach((s) => arcs.add(shotArc(s)))
  }, [shots])

  return <div ref={containerRef} className="three-container" />
}
