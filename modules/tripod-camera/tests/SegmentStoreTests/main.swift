// Logic tests for the rolling buffer's SegmentStore and Save Replay planning (no camera, no
// iOS needed).
//
// Compiled together with ../../ios/SegmentStore.swift and ../../ios/ReplayPlanning.swift and run by CI:
//   swiftc -swift-version 5 modules/tripod-camera/ios/SegmentStore.swift \
//     modules/tripod-camera/ios/ReplayPlanning.swift \
//     modules/tripod-camera/tests/SegmentStoreTests/main.swift -o segment-store-tests
//   ./segment-store-tests
// Exits with status 1 if any check fails.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
  checks += 1
  if !condition {
    failures += 1
    print("FAIL (line \(line)): \(message)")
  }
}

func test(_ name: String, _ body: () -> Void) {
  let before = failures
  body()
  print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

/// A segment with frames at 60 fps, from `start` to `end` capture-clock seconds.
func segment(_ index: Int, _ start: Double, _ end: Double, followsGap: Bool = false) -> BufferSegment {
  BufferSegment(
    index: index,
    fileName: String(format: "segment_%06d.mov", index),
    startTime: start,
    endTime: end,
    startedAt: Date(timeIntervalSince1970: start),
    endedAt: Date(timeIntervalSince1970: end),
    frameCount: Int(((end - start) * 60).rounded()),
    sizeBytes: 10_000_000,
    followsGap: followsGap,
    missingFrames: 0,
    maxFrameInterval: 1.0 / 60)
}

/// Consecutive 5 s segments starting at index `from`, beginning at capture time `t0`.
func continuousSegments(count: Int, from: Int = 1, t0: Double = 1000) -> [BufferSegment] {
  (0..<count).map { i in segment(from + i, t0 + Double(i) * 5, t0 + Double(i + 1) * 5) }
}

// MARK: - Expiration and cleanup

test("keeps ~130 s and deletes the oldest finalized segments, in order") {
  var store = SegmentStore(keepSeconds: 130)
  var deleted: [String] = []
  for s in continuousSegments(count: 40) {
    deleted += store.insert(s).filesToDelete
  }
  check(store.bufferedSeconds >= 130 && store.bufferedSeconds < 135, "buffered \(store.bufferedSeconds) s, want 130..<135")
  check(store.segments.count == 26, "kept \(store.segments.count) segments, want 26")
  check(store.segments.first?.index == 15, "oldest kept is \(String(describing: store.segments.first?.index)), want 15")
  check(store.segments.last?.index == 40, "newest kept is \(String(describing: store.segments.last?.index)), want 40")
  let expected = (1...14).map { String(format: "segment_%06d.mov", $0) }
  check(deleted == expected, "deleted \(deleted), want segments 1-14 in order")
  check(store.expiredCount == 14, "expiredCount \(store.expiredCount)")
  check(store.storageBytes == 26 * 10_000_000, "storageBytes \(store.storageBytes)")
  check(Set(deleted).isDisjoint(with: store.retainedFileNames), "a deleted file is still retained")
}

test("nothing expires before the buffer is full") {
  var store = SegmentStore(keepSeconds: 130)
  var deleted: [String] = []
  for s in continuousSegments(count: 26) {
    deleted += store.insert(s).filesToDelete
  }
  check(deleted.isEmpty, "deleted \(deleted) before 130 s were buffered")
  check(store.segments.count == 26, "count \(store.segments.count)")
}

test("the newest segment is never expired, even if longer than the retention") {
  var store = SegmentStore(keepSeconds: 10)
  let result = store.insert(segment(1, 0, 60))
  check(result.filesToDelete.isEmpty, "deleted the only segment")
  check(store.segments.map(\.index) == [1], "segments \(store.segments.map(\.index))")
  // 5 s of newer footage doesn't cover the 10 s retention yet, so segment 1 stays.
  let second = store.insert(segment(2, 60, 65))
  check(second.filesToDelete.isEmpty, "deleted \(second.filesToDelete) too early")
  let third = store.insert(segment(3, 65, 70))
  check(third.filesToDelete == ["segment_000001.mov"], "deleted \(third.filesToDelete)")
  check(store.segments.map(\.index) == [2, 3], "segments \(store.segments.map(\.index))")
}

test("only known, finalized segments can be deleted") {
  // The active segment is never inserted into the store, so it can't be in any delete list.
  var store = SegmentStore(keepSeconds: 20)
  var deleted: [String] = []
  for s in continuousSegments(count: 10) {
    deleted += store.insert(s).filesToDelete
  }
  check(deleted.allSatisfy { $0.hasPrefix("segment_") }, "deleted a non-segment file: \(deleted)")
  check(!deleted.contains("segment_000011.mov"), "deleted a segment that was never finalized")
}

// MARK: - Ordering

test("segments finishing out of order are stored in capture order") {
  var store = SegmentStore(keepSeconds: 130)
  let all = continuousSegments(count: 4)
  _ = store.insert(all[0])
  _ = store.insert(all[2])
  _ = store.insert(all[1])
  _ = store.insert(all[3])
  check(store.segments.map(\.index) == [1, 2, 3, 4], "order \(store.segments.map(\.index))")
  check(store.orderingErrors == 0, "orderingErrors \(store.orderingErrors)")
  check(store.unexpectedGaps == 0 && store.overlaps == 0, "gaps \(store.unexpectedGaps) overlaps \(store.overlaps)")
}

test("index order and timestamp order disagreeing is reported") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 100, 105))
  _ = store.insert(segment(2, 105, 110))
  _ = store.insert(segment(3, 90, 95)) // later index, earlier timestamps
  check(store.orderingErrors == 1, "orderingErrors \(store.orderingErrors), want 1")
}

test("a duplicate segment is rejected") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 0, 5))
  let again = store.insert(segment(1, 0, 5))
  check(!again.accepted, "duplicate accepted")
  check(store.segments.count == 1 && store.duplicates == 1, "count \(store.segments.count) duplicates \(store.duplicates)")
}

// MARK: - Continuity detection

test("continuity: exact joins are continuous") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 0, 5.0166666))
  let result = store.insert(segment(2, 5.0166666, 10.0333333))
  check(result.continuity == .continuous, "got \(result.continuity)")
}

test("continuity: a join within tolerance is continuous") {
  var store = SegmentStore(keepSeconds: 130, continuityTolerance: 0.001)
  _ = store.insert(segment(1, 0, 5))
  let result = store.insert(segment(2, 5.0004, 10))
  check(result.continuity == .continuous, "got \(result.continuity)")
}

test("continuity: unannounced gap, overlap, and expected gap are told apart") {
  var store = SegmentStore(keepSeconds: 1000)
  _ = store.insert(segment(1, 0, 5))
  let gap = store.insert(segment(2, 5.05, 10))
  let overlap = store.insert(segment(3, 9.98, 15))
  let paused = store.insert(segment(4, 30, 35, followsGap: true))
  if case .unexpectedGap(let s) = gap.continuity {
    check(abs(s - 0.05) < 1e-9, "gap size \(s)")
  } else {
    check(false, "segment 2: got \(gap.continuity), want unexpectedGap")
  }
  if case .overlap(let s) = overlap.continuity {
    check(abs(s - 0.02) < 1e-9, "overlap size \(s)")
  } else {
    check(false, "segment 3: got \(overlap.continuity), want overlap")
  }
  if case .expectedGap = paused.continuity {} else {
    check(false, "segment 4: got \(paused.continuity), want expectedGap")
  }
  check(store.unexpectedGaps == 1 && store.overlaps == 1 && store.expectedGaps == 1,
        "counters gaps \(store.unexpectedGaps) overlaps \(store.overlaps) expected \(store.expectedGaps)")
}

test("continuity: a gap is still found when the later segment finishes first") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 0, 5))
  _ = store.insert(segment(3, 10, 15))
  _ = store.insert(segment(2, 5, 9.9)) // ends 0.1 s before segment 3 starts
  check(store.unexpectedGaps == 1, "unexpectedGaps \(store.unexpectedGaps), want 1")
}

test("continuity: segments missing in between are not compared") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 0, 5))
  let result = store.insert(segment(3, 10, 15)) // segment 2 failed
  check(result.continuity == .unknown, "got \(result.continuity)")
  check(store.unexpectedGaps == 0, "unexpectedGaps \(store.unexpectedGaps)")
}

// MARK: - Protection

test("protected segments survive expiry and are deleted on release") {
  var store = SegmentStore(keepSeconds: 130)
  var deleted: [String] = []
  for s in continuousSegments(count: 5) {
    deleted += store.insert(s).filesToDelete
  }
  // Protect capture time 1002..1008: segments 1 (1000-1005) and 2 (1005-1010).
  guard let lease = store.protect(from: 1002, to: 1008) else {
    check(false, "protect returned nil")
    return
  }
  check(lease.segmentIndexes == [1, 2], "leased \(lease.segmentIndexes)")
  check(store.isProtected(1) && store.isProtected(2) && !store.isProtected(3), "protection flags")

  for s in continuousSegments(count: 30, from: 6, t0: 1025) {
    deleted += store.insert(s).filesToDelete
  }
  check(!deleted.contains("segment_000001.mov") && !deleted.contains("segment_000002.mov"),
        "a protected segment was deleted")
  check(deleted.contains("segment_000003.mov"), "unprotected expired segment 3 was not deleted")
  check(store.retired.map(\.index) == [1, 2], "retired \(store.retired.map(\.index))")
  check(store.retainedFileNames.contains("segment_000001.mov"), "protected file not retained")
  check(!store.segments.contains { $0.index == 1 }, "expired segment still counted in the buffer")

  let freed = store.release(lease)
  check(freed.sorted() == ["segment_000001.mov", "segment_000002.mov"], "freed \(freed)")
  check(store.retired.isEmpty && store.protectedSegmentCount == 0, "still protected after release")
  check(store.release(lease).isEmpty, "releasing twice freed files again")
}

test("overlapping leases: a segment is deleted only after the last release") {
  var store = SegmentStore(keepSeconds: 10)
  _ = store.insert(segment(1, 0, 5))
  _ = store.insert(segment(2, 5, 10))
  let a = store.protect(indexes: [1])
  let b = store.protect(indexes: [1, 2])
  check(a != nil && b != nil, "protect failed")
  let deleted = store.insert(segment(3, 10, 15)).filesToDelete + store.insert(segment(4, 15, 20)).filesToDelete
  check(deleted.isEmpty, "deleted \(deleted) while protected")
  check(store.release(a!).isEmpty, "freed segment 1 while lease b still holds it")
  check(store.release(b!).sorted() == ["segment_000001.mov", "segment_000002.mov"], "after last release")
}

test("releasing a lease on segments that never expired deletes nothing") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 0, 5))
  let lease = store.protect(indexes: [1])!
  check(store.release(lease).isEmpty, "deleted a live segment")
  check(store.segments.count == 1, "live segment removed")
}

test("protect returns nil when nothing matches") {
  var store = SegmentStore(keepSeconds: 130)
  _ = store.insert(segment(1, 0, 5))
  check(store.protect(from: 100, to: 200) == nil, "protected a range with no footage")
  check(store.protect(indexes: [42]) == nil, "protected an unknown index")
  check(store.activeLeaseCount == 0, "lease leaked")
}

test("reset (new buffer run) frees unprotected segments and keeps protected ones") {
  var store = SegmentStore(keepSeconds: 130)
  for s in continuousSegments(count: 3) {
    _ = store.insert(s)
  }
  let lease = store.protect(indexes: [2])!
  let deleted = store.reset()
  check(deleted.sorted() == ["segment_000001.mov", "segment_000003.mov"], "reset deleted \(deleted)")
  check(store.segments.isEmpty, "buffer not empty after reset")
  check(store.retainedFileNames == ["segment_000002.mov"], "retained \(store.retainedFileNames)")
  check(store.release(lease) == ["segment_000002.mov"], "protected file not freed after reset + release")
}

// MARK: - Save Replay: window selection

func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

test("replay window trims the first and last segment by real timestamps") {
  // Segments 1..10 cover capture time 1000-1050; press at 1047.3, 20 s requested.
  let segments = continuousSegments(count: 10)
  guard let plan = ReplayPlanner.plan(segments: segments, endpoint: 1047.3, requestedSeconds: 20) else {
    check(false, "no plan")
    return
  }
  check(plan.segmentIndexes == [6, 7, 8, 9, 10], "segments \(plan.segmentIndexes)")
  check(near(plan.pieces[0].fileOffset, 2.3) && near(plan.pieces[0].duration, 2.7), "first piece \(plan.pieces[0])")
  check(near(plan.pieces[4].fileOffset, 0) && near(plan.pieces[4].duration, 2.3), "last piece \(plan.pieces[4])")
  check(near(plan.duration, 20), "duration \(plan.duration)")
  check(near(plan.captureStart, 1027.3) && near(plan.captureEnd, 1047.3), "span \(plan.captureStart)-\(plan.captureEnd)")
  check(!plan.isShort && plan.missingInside == 0, "short \(plan.isShort) missing \(plan.missingInside)")
}

test("replay window ending exactly on a segment boundary has no sliver piece") {
  let segments = continuousSegments(count: 10)
  let plan = ReplayPlanner.plan(segments: segments, endpoint: 1030, requestedSeconds: 10)!
  check(plan.segmentIndexes == [5, 6], "segments \(plan.segmentIndexes)")
  check(near(plan.duration, 10), "duration \(plan.duration)")
}

test("replay longer than the buffer saves what is available") {
  let segments = continuousSegments(count: 6) // 1000-1030
  let plan = ReplayPlanner.plan(segments: segments, endpoint: 1030, requestedSeconds: 120)!
  check(near(plan.duration, 30), "duration \(plan.duration)")
  check(plan.isShort, "not flagged short")
  check(plan.segmentIndexes == Array(1...6), "segments \(plan.segmentIndexes)")
}

test("replay window ignores footage after the endpoint") {
  // The cut makes the segment containing the press end after it; the plan must stop at the press.
  let segments = [segment(1, 0, 5), segment(2, 5, 7.25)]
  let plan = ReplayPlanner.plan(segments: segments, endpoint: 7.2, requestedSeconds: 10)!
  check(near(plan.captureEnd, 7.2), "ends at \(plan.captureEnd)")
  check(near(plan.duration, 7.2), "duration \(plan.duration)")
}

test("replay window reports capture pauses and missing segments inside it") {
  let segments = [segment(1, 0, 5), segment(2, 5, 10), segment(4, 15, 20)] // segment 3 failed
  let plan = ReplayPlanner.plan(segments: segments, endpoint: 20, requestedSeconds: 20)!
  check(plan.segmentIndexes == [1, 2, 4], "segments \(plan.segmentIndexes)")
  check(near(plan.missingInside, 5), "missing \(plan.missingInside)")
  check(near(plan.duration, 15) && plan.isShort, "duration \(plan.duration)")
}

test("replay window with no footage returns nil") {
  check(ReplayPlanner.plan(segments: [], endpoint: 100, requestedSeconds: 20) == nil, "plan from nothing")
  let old = [segment(1, 0, 5)]
  check(ReplayPlanner.plan(segments: old, endpoint: 100, requestedSeconds: 20) == nil, "plan from footage outside the window")
}

// MARK: - Save Replay: protection during export

test("segments of a replay stay on disk while exporting, then expire normally") {
  var store = SegmentStore(keepSeconds: 130)
  var deleted: [String] = []
  for s in continuousSegments(count: 30) { // 1000-1150
    deleted += store.insert(s).filesToDelete
  }
  let plan = ReplayPlanner.plan(segments: store.segments, endpoint: 1150, requestedSeconds: 120)!
  let lease = store.protect(indexes: plan.segmentIndexes)!
  check(lease.segmentIndexes == plan.segmentIndexes, "lease \(lease.segmentIndexes)")
  // Recording keeps going for another minute while the export runs.
  for s in continuousSegments(count: 12, from: 31, t0: 1150) {
    deleted += store.insert(s).filesToDelete
  }
  let planned = Set(plan.pieces.map(\.fileName))
  check(planned.isDisjoint(with: deleted), "a segment still being exported was deleted")
  check(planned.isSubset(of: store.retainedFileNames), "a planned file is no longer retained")
  let freed = store.release(lease)
  check(!freed.isEmpty && Set(freed).isSubset(of: planned), "released \(freed)")
  check(store.retired.isEmpty, "retired \(store.retired.map(\.index))")
}

// MARK: - Save Replay: file names

test("replay file names are unique and well formed") {
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  var taken: Set<String> = []
  var suffixes = [0xABCDEF, 0xABCDEF, 0x123456] // first suffix collides on the second call
  let next = { () -> Int in suffixes.isEmpty ? Int.random(in: 0..<0x100_0000) : suffixes.removeFirst() }
  let first = ReplayFileNaming.makeFileName(date: date, fileExtension: "mp4", isTaken: { taken.contains($0) }, randomSuffix: next)!
  taken.insert(first)
  let second = ReplayFileNaming.makeFileName(date: date, fileExtension: "mp4", isTaken: { taken.contains($0) }, randomSuffix: next)!
  check(first != second, "same name twice: \(first)")
  check(first.hasPrefix("replay_") && first.hasSuffix("_abcdef.mp4"), "first \(first)")
  check(second.hasSuffix("_123456.mp4"), "second \(second)")
  let parts = first.dropLast(4).split(separator: "_")
  check(parts.count == 4 && parts[1].count == 8 && parts[2].count == 6, "format \(first)")
  check(ReplayFileNaming.makeFileName(date: date, fileExtension: "mp4", isTaken: { _ in true }, randomSuffix: { 1 }) == nil,
        "returned a name although every candidate was taken")
}

// MARK: - Save Replay: export cleanup and repeated requests

final class Box<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

/// Runs async code from these synchronous tests (detached, so it never needs the blocked main thread).
func runBlocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box = Box<T?>(nil)
  Task.detached {
    box.value = await body()
    semaphore.signal()
  }
  semaphore.wait()
  return box.value!
}

struct FakeError: Error {}

func scratchDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("tripod-tests-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

let samplePlan = ReplayPlanner.plan(segments: continuousSegments(count: 4), endpoint: 1020, requestedSeconds: 10)!

test("a failed export leaves no partial file and releases the protection") {
  let dir = scratchDirectory()
  let temp = dir.appendingPathComponent("work/replay.mp4")
  let destination = dir.appendingPathComponent("Replays/replay.mp4")
  let releases = Box(0)
  let result = runBlocking {
    await ReplaySaveRunner.run(
      plan: samplePlan, tempURL: temp, finalURL: destination,
      export: { _, url in
        try Data(repeating: 1, count: 1024).write(to: url) // half-written file, then failure
        throw FakeError()
      },
      verify: { _ in 10 },
      release: { releases.value += 1 })
  }
  if case .failure(let error) = result {
    check(error.code == "ERR_EXPORT_FAILED", "code \(error.code)")
  } else {
    check(false, "export failure reported as success")
  }
  check(!FileManager.default.fileExists(atPath: temp.path), "partial temp file left behind")
  check(!FileManager.default.fileExists(atPath: destination.path), "final file created after a failure")
  check(releases.value == 1, "released \(releases.value) times")
  try? FileManager.default.removeItem(at: dir)
}

test("an unreadable export is deleted and never moved into Replays") {
  let dir = scratchDirectory()
  let temp = dir.appendingPathComponent("work/replay.mp4")
  let destination = dir.appendingPathComponent("Replays/replay.mp4")
  let releases = Box(0)
  let result = runBlocking {
    await ReplaySaveRunner.run(
      plan: samplePlan, tempURL: temp, finalURL: destination,
      export: { _, url in try Data(repeating: 1, count: 1024).write(to: url) },
      verify: { _ in throw ReplayError(code: "X", message: "unreadable") },
      release: { releases.value += 1 })
  }
  if case .failure(let error) = result {
    check(error.code == "ERR_VERIFY_FAILED", "code \(error.code)")
  } else {
    check(false, "verify failure reported as success")
  }
  check(!FileManager.default.fileExists(atPath: temp.path), "unverified temp file left behind")
  check(!FileManager.default.fileExists(atPath: destination.path), "unverified file moved into Replays")
  check(releases.value == 1, "released \(releases.value) times")
  try? FileManager.default.removeItem(at: dir)
}

test("a successful export is moved into Replays and releases the protection") {
  let dir = scratchDirectory()
  let temp = dir.appendingPathComponent("work/replay.mp4")
  let destination = dir.appendingPathComponent("Replays/replay.mp4")
  let releases = Box(0)
  let result = runBlocking {
    await ReplaySaveRunner.run(
      plan: samplePlan, tempURL: temp, finalURL: destination,
      export: { _, url in try Data(repeating: 1, count: 1024).write(to: url) },
      verify: { _ in 9.98 },
      release: { releases.value += 1 })
  }
  if case .success(let output) = result {
    check(output.url == destination && near(output.durationSeconds, 9.98), "output \(output)")
  } else {
    check(false, "success reported as \(result)")
  }
  check(FileManager.default.fileExists(atPath: destination.path), "final file missing")
  check(!FileManager.default.fileExists(atPath: temp.path), "temp file left behind")
  check(releases.value == 1, "released \(releases.value) times")
  try? FileManager.default.removeItem(at: dir)
}

test("an existing replay is never overwritten") {
  let dir = scratchDirectory()
  let temp = dir.appendingPathComponent("work/replay.mp4")
  let destination = dir.appendingPathComponent("Replays/replay.mp4")
  try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? Data([9, 9, 9]).write(to: destination)
  let result = runBlocking {
    await ReplaySaveRunner.run(
      plan: samplePlan, tempURL: temp, finalURL: destination,
      export: { _, url in try Data(repeating: 1, count: 1024).write(to: url) },
      verify: { _ in 10 },
      release: {})
  }
  if case .success = result { check(false, "overwrote an existing replay") }
  check((try? Data(contentsOf: destination)) == Data([9, 9, 9]), "existing replay was modified")
  check(!FileManager.default.fileExists(atPath: temp.path), "temp file left behind")
  try? FileManager.default.removeItem(at: dir)
}

final class JobLog: @unchecked Sendable {
  let lock = NSLock()
  var order: [Int] = []
  var running = 0
  var maxRunning = 0
  func begin() { lock.lock(); running += 1; maxRunning = max(maxRunning, running); lock.unlock() }
  func end(_ id: Int) { lock.lock(); running -= 1; order.append(id); lock.unlock() }
}

test("repeated save requests export one at a time, in press order") {
  let log = JobLog()
  let queue = SerialJobQueue()
  let done = DispatchSemaphore(value: 0)
  for id in 1...5 {
    queue.enqueue {
      log.begin()
      try? await Task.sleep(nanoseconds: 20_000_000)
      log.end(id)
      if id == 5 { done.signal() }
    }
  }
  check(queue.pendingCount >= 1, "nothing pending right after enqueueing")
  let finished = done.wait(timeout: .now() + 10) == .success
  check(finished, "jobs did not finish")
  check(log.order == [1, 2, 3, 4, 5], "order \(log.order)")
  check(log.maxRunning == 1, "\(log.maxRunning) exports ran at the same time")
  // The queue keeps working after it drained.
  let again = DispatchSemaphore(value: 0)
  queue.enqueue { again.signal() }
  check(again.wait(timeout: .now() + 5) == .success, "queue stalled after draining")
}

print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
  exit(1)
}
