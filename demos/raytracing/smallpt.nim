# Weave
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Warning: the original code-golfing is pretty extreme
#          The worse being declaring, resetting non-loop variable
#          in for-loop, including the random seed ...
import math, strformat, os, strutils

type Vec = object
  x, y, z: float64

func vec(x, y, z: float64 = 0): Vec =
  Vec(x: x, y: y, z: z)
func `+`(a, b: Vec): Vec =
  vec(a.x+b.x, a.y+b.y, a.z+b.z)
func `-`(a, b: Vec): Vec =
  vec(a.x-b.x, a.y-b.y, a.z-b.z)
func `*`(a: Vec, t: float64): Vec =
  vec(a.x*t, a.y*t, a.z*t)
func `*.`(a, b: Vec): Vec =
  # hadamard product
  vec(a.x*b.x, a.y*b.y, a.z*b.z)
func norm(a: Vec): Vec =
  # Warning! Warning! The original code
  # mutate the vec in-place AND returns a reference to the mutated input
  a * (1/sqrt(a.x*a.x + a.y*a.y + a.z*a.z))
func dot(a, b: Vec): float64 =
  a.x*b.x + a.y*b.y + a.z*b.z
func cross(a, b: Vec): Vec =
  vec(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)

type
  Ray = object
    o, d: Vec # origin, direction

  Reflection = enum
    Diffuse, Specular, Refractive

  Sphere = object
    radius: float64
    pos, emit, color: Vec
    refl: Reflection

func ray(origin: Vec, direction: Vec): Ray =
  result.o = origin
  result.d = direction

func intersect(self: Sphere, ray: Ray): float64 =
  ## Returns distance, 0 if no hit
  ## Solve t^2*d.d + 2*t*(o-p).d + (o-p).(o-p)-R^2 = 0
  let op = self.pos - ray.o
  const eps = 1e-4
  let b = op.dot(ray.d)
  var det = b*b - op.dot(op) + self.radius*self.radius
  if det < 0.0:
    return 0.0

  det = sqrt(det)
  block:
    let t = b-det
    if t > eps:
      return t
  block:
    let t = b+det
    if t > eps:
      return t
  return 0.0

const spheres = [ # Scene: radius, position, emission, color, material                           # Walls approximated by very large spheres
  Sphere(radius:1e5, pos:vec( 1e5+1,  40.8, 81.6),    color:vec(0.75,0.25,0.25),refl:Diffuse),   # Left
  Sphere(radius:1e5, pos:vec(-1e5+99, 40.8, 81.6),    color:vec(0.25,0.25,0.75),refl:Diffuse),   # Right
  Sphere(radius:1e5, pos:vec(50,      40.8, 1e5),     color:vec(0.75,0.75,0.75),refl:Diffuse),   # Back
  Sphere(radius:1e5, pos:vec(50,      40.8,-1e5+170),                           refl:Diffuse),   # Front
  Sphere(radius:1e5, pos:vec(50,       1e5, 81.6),    color:vec(0.75,0.75,0.75),refl:Diffuse),   # Bottom
  Sphere(radius:1e5, pos:vec(50, -1e5+81.6, 81.6),    color:vec(0.75,0.75,0.75),refl:Diffuse),   # Top
  Sphere(radius:16.5,pos:vec(27,      16.5, 47),      color:vec(1,1,1)*0.999,   refl:Specular),  # Mirror
  Sphere(radius:16.5,pos:vec(73,      16.5, 78),      color:vec(1,1,1)*0.999,   refl:Refractive),# Glass
  Sphere(radius:600, pos:vec(50, 681.6-0.27,81.6), emit:vec(12,12,12),          refl:Diffuse),   # Light
]
func clamp(x: float64): float64 {.inline.} =
  if x < 0: 0.0 else: (if x > 1: 1.0 else: x)

func toInt(x: float64): int32 =
  # This seems to do gamma correction by 2.2
  int32(
    pow(clamp(x),1/2.2) * 255 + 0.5
  )

func intersect(r: Ray, t: var float64, id: var int32): bool =
  # out parameters ...
  const inf = 1e20
  t = inf
  for i in countdown(spheres.len-1, 0):
    let d = spheres[i].intersect(r)
    if d != 0 and d < t:
      t = d
      id = i.int32
  return t < inf

proc erand48(xi: var array[3, cushort]): cdouble {.importc, header:"<stdlib.h>", sideeffect.} # Need the same RNG for comparison

proc radiance(r: Ray, depth: int32, xi: var array[3, cushort]): Vec =
  var t: float64                      # distance to intersection
  var id = 0'i32                      # id of intersected object
  if not r.intersect(t, id):          # if miss return black
    return vec()
  template obj: untyped = spheres[id] # alias the hit object

  let x = r.o + r.d * t
  let n = norm(x-obj.pos);
  let nl = if n.dot(r.d) < 0: n else: n * -1
  var f = obj.color
  let p = max(f.x, max(f.y, f.z))     # max reflect
  let depth=depth+1
  if depth>5:
    if erand48(xi) < p:
      f = f*(1/p)
    else:
      return obj.emit                 # Russian Roulette

  if obj.refl == Diffuse:             # ideal diffuse reflection
    let
      r1  = 2*PI*erand48(xi)
      r2  = erand48(xi)
      r2s = sqrt(r2)
      w   = nl
      u   = (if w.x.abs() > 0.1: vec(0,1) else: vec(1)).cross(w).norm()
      v   = w.cross(u)
      d   = (u*cos(r1)*r2s + v*sin(r1)*r2s + w*sqrt(1-r2)).norm()
    return obj.emit + f *. radiance(ray(x, d), depth, xi)
  elif obj.refl == Specular:          # ideal specular reflection
    return obj.emit + f *. radiance(ray(x, r.d - n*2*n.dot(r.d)), depth, xi)

  # Dielectric refraction
  let
    reflRay = ray(x, r.d - n*2*n.dot(r.d))
    into = n.dot(nl) > 0              # Ray from outside going in
    nc = 1.0
    nt = 1.5
    nnt = if into: nc/nt else: nt/nc
    ddn = r.d.dot(nl)
    cos2t = 1-nnt*nnt*(1-ddn*ddn)

  if cos2t < 0:
    return obj.emit + f *. radiance(reflRay, depth, xi)
  let
    tdir = (r.d*nnt - n*(if into: 1 else: -1)*(ddn*nnt+sqrt(cos2t))).norm()
    a = nt - nc
    b = nt + nc
    R0 = a*a/(b*b)
    c = 1 - (if into: -ddn else: tdir.dot(n))
    Re = R0 + (1-R0)*c*c*c*c*c
    Tr = 1-Re
    P = 0.25+0.5*Re
    RP = Re/P
    TP = Tr/(1-P)
  return obj.emit + f *. (block:
    if depth>2:       # Russian roulette
      if erand48(xi)<P:
        radiance(reflRay, depth, xi)*RP
      else:
        radiance(ray(x, tdir), depth, xi)*TP
    else:
      # Note: to exacly reproduce the C++ result,
      # since we have a random function and C++ seem to resolve
      # from right to left, we exchange our processing order
      radiance(ray(x, tdir), depth, xi)*Tr +
        radiance(reflRay, depth, xi)*Re
  )

proc tracer_single(C: var seq[Vec], w, h: static int, samples: int) =
  const
    cam = ray(vec(50,52,295.6), vec(0,-0.042612,-1).norm())
    cx = vec(w*0.5135/h)
    cy = cx.cross(cam.d).norm()*0.5135

  for y in 0 ..< h:                       # Loop over image rows
    stderr.write &"\rRendering ({samples*4} samples per pixel) {100.0*y.float64/float(h-1):5.2f}%"
    var xi = [cushort 0, 0, cushort y*y*y]
    for x in 0 ..< w:                     # Loop over columns
      let i = (h-y-1)*w+x
      for sy in 0 ..< 2:                  # 2x2 subpixel rows
        for sx in 0 ..< 2:                # 2x2 subpixel cols
          var r = vec()
          for s in 0 ..< samples:
            let
              r1 = 2*erand48(xi)
              dx = if r1<1: sqrt(r1)-1 else: 1-sqrt(2-r1)
              r2 = 2*erand48(xi)
              dy = if r2<1: sqrt(r2)-1 else: 1-sqrt(2-r2)
              d = cx*(((sx.float64 + 0.5 + dx)/2 + x.float64)/w - 0.5) +
                  cy*(((sy.float64 + 0.5 + dy)/2 + y.float64)/h - 0.5) + cam.d
            let dnorm = d.norm() # Warning, the original code is deceptive since d is modified by d.norm()
            let ray = ray(cam.o + dnorm*140'f64, dnorm)
            let rad = radiance(ray, depth = 0, xi)
            r = r + rad * (1.0/samples.float64)
          C[i] = C[i] + vec(r.x.clamp(), r.y.clamp(), r.z.clamp()) * 0.25 # / num subpixels

when compileOption("threads"):
  import ../../weave

  proc tracer_threaded(C: var seq[Vec], w, h: static int, samples: int) =
    # This gives the exact same result as single threaded and GCC OpenMP
    # assumes that C++ calls resolve function calls from right to left

    const
      cam = ray(vec(50,52,295.6), vec(0,-0.042612,-1).norm())
      cx = vec(w*0.5135/h)
      cy = cx.cross(cam.d).norm()*0.5135

     # We need the buffer raw address
    let buf = cast[ptr UncheckedArray[Vec]](C[0].addr)

    init(Weave)

    parallelFor y in 0 ..< h:               # Loop over image rows
      captures: {buf, samples}
      stderr.write &"\rRendering ({samples*4} samples per pixel) {100.0*y.float64/float(h-1):5.2f}%"
      var xi = [cushort 0, 0, cushort y*y*y]
      for x in 0 ..< w:                     # Loop over columns
        let i = (h-y-1)*w+x
        for sy in 0 ..< 2:                  # 2x2 subpixel rows
          for sx in 0 ..< 2:                # 2x2 subpixel cols
            var r = vec()
            for s in 0 ..< samples:
              loadBalance(Weave)            # If we are tracing a complex rows, ensure we delegate loop iterations
              let
                r1 = 2*erand48(xi)
                dx = if r1<1: sqrt(r1)-1 else: 1-sqrt(2-r1)
                r2 = 2*erand48(xi)
                dy = if r2<1: sqrt(r2)-1 else: 1-sqrt(2-r2)
                d = cx*(((sx.float64 + 0.5 + dx)/2 + x.float64)/w - 0.5) +
                    cy*(((sy.float64 + 0.5 + dy)/2 + y.float64)/h - 0.5) + cam.d
              let dnorm = d.norm() # Warning, the original code is deceptive since d is modified by d.norm()
              let ray = ray(cam.o + dnorm*140'f64, dnorm)
              let rad = radiance(ray, depth = 0, xi)
              r = r + rad * (1.0/samples.float64)
            buf[i] = buf[i] + vec(r.x.clamp(), r.y.clamp(), r.z.clamp()) * 0.25 # / num subpixels

    exit(Weave) # This implicitly blocks until tasks are all done

  proc tracer_nested_parallelism(C: var seq[Vec], w, h: static int, samples: int) =
    # The results are different since the RNG will not be seeded the same
    # The rng needs to be thread-local but task stealing + nested parallelismmakes the
    # actual executing thread pretty random.
    # So the RNG has been moved to an inner scope,
    # downside is that resulting images have horizontal noise instead of pointwise

    const
      cam = ray(vec(50,52,295.6), vec(0,-0.042612,-1).norm())
      cx = vec(w*0.5135/h)
      cy = cx.cross(cam.d).norm()*0.5135

     # We need the buffer raw address
    let buf = cast[ptr UncheckedArray[Vec]](C[0].addr)

    init(Weave)

    parallelFor y in 0 ..< h:               # Loop over image rows
      captures: {buf, samples}
      stderr.write &"\rRendering ({samples*4} samples per pixel) {100.0*y.float64/float(h-1):5.2f}%"
      parallelFor x in 0 ..< w:             # Loop over columns
        captures: {y, buf, samples}
        var xi = [cushort 0, 0, cushort y*y*y]
        let i = (h-y-1)*w+x
        for sy in 0 ..< 2:                  # 2x2 subpixel rows
          for sx in 0 ..< 2:                # 2x2 subpixel cols
            var r = vec()
            for s in 0 ..< samples:
              loadBalance(Weave)            # If we are tracing a complex ray, ensure we delegate loop iterations
              let
                r1 = 2*erand48(xi)
                dx = if r1<1: sqrt(r1)-1 else: 1-sqrt(2-r1)
                r2 = 2*erand48(xi)
                dy = if r2<1: sqrt(r2)-1 else: 1-sqrt(2-r2)
                d = cx*(((sx.float64 + 0.5 + dx)/2 + x.float64)/w - 0.5) +
                    cy*(((sy.float64 + 0.5 + dy)/2 + y.float64)/h - 0.5) + cam.d
              let dnorm = d.norm() # Warning, the original code is deceptive since d is modified by d.norm()
              let ray = ray(cam.o + dnorm*140'f64, dnorm)
              let rad = radiance(ray, depth = 0, xi)
              r = r + rad * (1.0/samples.float64)
            buf[i] = buf[i] + vec(r.x.clamp(), r.y.clamp(), r.z.clamp()) * 0.25 # / num subpixels

    exit(Weave) # This implicitly blocks until tasks are all done

proc main() =
  const w = 1024
  const h = 768
  var samples = 10
  var outFile = "image.ppm"
  let exeName = getAppFilename().extractFilename()
  if paramCount() == 0:
    echo &"Usage: {exeName} <samples per pixel:{samples*4}> <output image:{outFile}>"
    echo &"Running with default samples = {samples*4}, output = {outFile}"
  elif paramCount() == 1:
    samples = paramStr(1).parseInt() div 4 # (2*2 blocks)
    samples = max(samples, 1)
  elif paramCount() == 2:
    samples = paramStr(1).parseInt() div 4
    samples = max(samples, 1)
    outFile = paramStr(2)
  else:
    echo &"Usage: {exeName} <samples per pixel:{samples}> <output image:{outFile}>"

  var C = newSeq[Vec](w*h)
  when compileOption("threads"):
    echo "Running multithreaded. (⚠️ Stack overflow at depth 4480 (400 samples)?)"
    tracer_threaded(C, w, h, samples)
    # tracer_nested_parallelism(C, w, h, samples)
  else:
    # Note: in the Weave repo, due to nim.cfg,
    # --threads:on is automatic, so you need to pass --threads:off explicitly
    echo "Running single-threaded."
    tracer_single(C, w, h, samples)

  let f = open(outFile, mode = fmWrite)
  defer: f.close()
  f.write &"P3\n{w} {h}\n255\n"
  for i in 0 ..< w*h:
    f.write &"{C[i].x.toInt()} {C[i].y.toInt()} {C[i].z.toInt()} "

  stderr.write "\nDone.\n"
main()
