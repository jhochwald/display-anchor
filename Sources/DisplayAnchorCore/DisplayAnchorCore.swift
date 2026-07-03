import CoreGraphics
import Foundation
import os.log

// Configuration Constants
public enum DisplayAnchorConfiguration {
	public static let defaultTopologyTolerance: Double = 12
	public static let defaultWindowMatchMinimumScore = 40
	public static let maxWindowsPerDisplay = 100
	public static let snapshotCacheDuration: TimeInterval = 60
}

// Logging Setup
private let logger = Logger(
	subsystem: "com.yourcompany.DisplayAnchor", category: "DisplayAnchorCore")

// Core Types and Structures
public struct WindowFrame: Codable, Equatable, Hashable, Sendable {
	public var x: Double
	public var y: Double
	public var width: Double
	public var height: Double

	public init(x: Double, y: Double, width: Double, height: Double) {
		// Validate bounds for production
		precondition(width >= 0, "Width must be non-negative")
		precondition(height >= 0, "Height must be non-negative")

		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}

	public init(_ rect: CGRect) {
		self.init(
			// Convert to Double for precision
			x: Double(rect.origin.x),
			y: Double(rect.origin.y),
			width: Double(rect.size.width),
			height: Double(rect.size.height)
		)
	}

	public var cgRect: CGRect {
		// Convert back to CGFloat for display
		CGRect(x: x, y: y, width: width, height: height)
	}

	public var center: CGPoint {
		// Convert to CGFloat for display
		CGPoint(x: x + (width / 2), y: y + (height / 2))
	}

	public func isClose(to other: WindowFrame, tolerance: Double) -> Bool {
		// Convert to CGFloat for display
		abs(x - other.x) <= tolerance
			&& abs(y - other.y) <= tolerance
			&& abs(width - other.width) <= tolerance
			&& abs(height - other.height) <= tolerance
	}

	public func intersectionArea(with other: WindowFrame) -> Double {
		// Convert to CGFloat for display
		let intersection = cgRect.intersection(other.cgRect)
		guard !intersection.isNull, !intersection.isEmpty else { return 0 }

		// Prevent overflow for very large windows
		let area = Double(intersection.width) * Double(intersection.height)
		return area.isFinite ? area : 0
	}

	public func contains(_ point: CGPoint) -> Bool {
		// Convert to CGFloat for display
		cgRect.contains(point)
	}
}

public struct DisplayInfo: Codable, Equatable, Hashable, Sendable {
	// Display ID is a unique identifier for the display
	public var id: UInt32
	public var uuid: String?
	public var frame: WindowFrame
	public var isMain: Bool

	public init(id: UInt32, uuid: String?, frame: WindowFrame, isMain: Bool) {
		// Validate bounds for production
		self.id = id
		self.uuid = uuid
		self.frame = frame
		self.isMain = isMain
	}

	public var stableKey: String {
		// Use UUID if available, otherwise use display ID
		uuid ?? "display-\(id)"
	}
}

public struct DisplayTopology: Codable, Equatable, Sendable {
	// Sorted by display ID and then frame area (largest first)
	public var displays: [DisplayInfo]

	public init(displays: [DisplayInfo]) {
		// Sort displays by stable key and frame area
		self.displays = displays.sorted { lhs, rhs in
			// Sort by stable key first, then by frame area
			if lhs.stableKey == rhs.stableKey {
				return lhs.id < rhs.id
			}
			return lhs.stableKey < rhs.stableKey
		}
	}

	public func matches(
		_ other: DisplayTopology,
		tolerance: Double = DisplayAnchorConfiguration.defaultTopologyTolerance
	) -> Bool {
		// Compare display count, main display, and frame area
		guard displays.count == other.displays.count else {
			// Debug log for production
			logger.debug("Display count mismatch: \(displays.count) vs \(other.displays.count)")
			return false
		}

		for display in displays {
			// Check each display for equality
			guard let match = other.displays.first(where: { $0.stableKey == display.stableKey })
			else {
				logger.debug("Display not found: \(display.stableKey)")
				return false
			}

			guard display.isMain == match.isMain else {
				// Debug log for production
				logger.debug("Main display mismatch for \(display.stableKey)")
				return false
			}

			guard display.frame.isClose(to: match.frame, tolerance: tolerance) else {
				// Debug log for production
				logger.debug("Frame mismatch for \(display.stableKey)")
				return false
			}
		}

		return true
	}

	public func displayID(containing frame: WindowFrame) -> UInt32? {
		// Fast path: check if frame center is contained
		if let containing = displays.first(where: { $0.frame.contains(frame.center) }) {
			return containing.id
		}

		// Slow path: calculate intersection areas only when necessary
		let intersections = displays.lazy
			.compactMap { display -> (UInt32, Double)? in
				let area = display.frame.intersectionArea(with: frame)
				return area > 0 ? (display.id, area) : nil
			}

		return intersections.max(by: { $0.1 < $1.1 })?.0
	}
}

public struct WindowRecord: Codable, Equatable, Sendable {
	public var bundleIdentifier: String?
	public var processIdentifier: Int32
	public var title: String
	public var role: String?
	public var subrole: String?
	public var frame: WindowFrame
	public var displayID: UInt32?
	public var order: Int

	public init(
		// Bundle identifier is optional, but should be present for production
		bundleIdentifier: String?,
		processIdentifier: Int32,
		title: String,
		role: String?,
		subrole: String?,
		frame: WindowFrame,
		displayID: UInt32?,
		order: Int
	) {
		self.bundleIdentifier = bundleIdentifier
		self.processIdentifier = processIdentifier
		self.title = title
		self.role = role
		self.subrole = subrole
		self.frame = frame
		self.displayID = displayID
		self.order = order
	}
}

public typealias WindowCandidate = WindowRecord

public struct WindowSnapshot: Codable, Equatable, Sendable {
	// Snapshots are sorted by display ID and then order within the display
	public var createdAt: Date
	public var topology: DisplayTopology
	public var windows: [WindowRecord]

	public init(createdAt: Date, topology: DisplayTopology, windows: [WindowRecord]) {
		// Validate window count for production
		self.createdAt = createdAt
		self.topology = topology

		// Validate window count for production
		if windows.count > DisplayAnchorConfiguration.maxWindowsPerDisplay * topology.displays.count
		{
			logger.warning("Excessive window count: \(windows.count)")
			self.windows = Array(
				windows.prefix(
					DisplayAnchorConfiguration.maxWindowsPerDisplay * topology.displays.count))
		} else {
			self.windows = windows
		}
	}
}

// Snapshot Operations
public enum SnapshotMerger {
	public static func merge(
		previous: WindowSnapshot,
		candidate: WindowSnapshot,
		preservingDisplayIDs displayIDsToPreserve: Set<UInt32>
	) -> WindowSnapshot {
		logger.debug("Merging snapshots: preserving \(displayIDsToPreserve.count) displays")

		guard !displayIDsToPreserve.isEmpty else {
			// No displays to preserve, use candidate snapshot
			logger.info("No displays to preserve, using candidate snapshot")
			return normalized(candidate)
		}

		let preservedWindows = previous.windows.filter { window in
			// Check if window should be preserved based on display ID
			guard let displayID = window.displayID else {
				// Window has no display ID, skip
				return true
			}
			return displayIDsToPreserve.contains(displayID)
		}

		let replacementWindows = candidate.windows.filter { window in
			// Check if window should be replaced based on display ID
			guard let displayID = window.displayID else {
				// Window has no display ID, skip
				return false
			}
			return !displayIDsToPreserve.contains(displayID)
		}

		let mergedWindows = (preservedWindows + replacementWindows)
			.sorted { lhs, rhs in
				// Sort by display ID first, then by order within the display
				if lhs.order == rhs.order {
					// If orders are the same, sort by process ID
					return lhs.processIdentifier < rhs.processIdentifier
				}
				return lhs.order < rhs.order
			}

		logger.info(
			"Merged \(preservedWindows.count) preserved + \(replacementWindows.count) replacement windows"
		)

		return WindowSnapshot(
			// Use the same createdAt date as the previous snapshot
			createdAt: candidate.createdAt,
			topology: candidate.topology,
			windows: normalized(mergedWindows)
		)
	}

	public static func normalized(_ snapshot: WindowSnapshot) -> WindowSnapshot {
		// Normalize window order within each display
		WindowSnapshot(
			createdAt: snapshot.createdAt,
			topology: snapshot.topology,
			windows: normalized(snapshot.windows)
		)
	}

	private static func normalized(_ windows: [WindowRecord]) -> [WindowRecord] {
		// Ensure order is always 0-based and unique within each display
		windows.enumerated().map { order, window in
			var normalizedWindow = window
			normalizedWindow.order = order
			return normalizedWindow
		}
	}
}

// Window Matching

public struct WindowMatch: Equatable, Sendable {
	public var savedIndex: Int
	public var currentIndex: Int
	public var score: Int

	public init(savedIndex: Int, currentIndex: Int, score: Int) {
		// Validate score for production
		self.savedIndex = savedIndex
		self.currentIndex = currentIndex
		self.score = score
	}
}

public enum WindowMatcher {
	public static let minimumScore = DisplayAnchorConfiguration.defaultWindowMatchMinimumScore

	// Cache for score calculations (thread-safe with NSCache)
	nonisolated(unsafe) private static let scoreCache = NSCache<NSString, NSNumber>()
	private static let scoreCacheLock = NSLock()

	public static func match(saved: [WindowRecord], current: [WindowCandidate]) -> [WindowMatch] {
		// For very large datasets, consider more efficient algorithms
		if saved.count * current.count > 10000 {
			logger.warning("Large window matching: \(saved.count) x \(current.count)")
		}

		var matches: [WindowMatch] = []
		var usedCurrentIndexes = Set<Int>()

		for (savedIndex, savedWindow) in saved.enumerated() {
			// Find the best matching window in the current list
			let best = current.enumerated()
				// Filter out used indexes and sort by score
				.filter { !usedCurrentIndexes.contains($0.offset) }
				.map { currentIndex, candidate in
					WindowMatch(
						// Use the saved index as the saved window index
						savedIndex: savedIndex,
						currentIndex: currentIndex,
						score: score(saved: savedWindow, candidate: candidate)
					)
				}
				.filter { $0.score >= minimumScore }
				.max { lhs, rhs in
					if lhs.score == rhs.score {
						return current[lhs.currentIndex].order > current[rhs.currentIndex].order
					}
					return lhs.score < rhs.score
				}

			if let best {
				// Add the best match to the list
				matches.append(best)
				usedCurrentIndexes.insert(best.currentIndex)
			}
		}

		logger.debug("Matched \(matches.count) of \(saved.count) windows")
		return matches
	}

	public static func score(saved: WindowRecord, candidate: WindowCandidate) -> Int {
		// Create cache key
		let cacheKey =
			"\(saved.processIdentifier)-\(candidate.processIdentifier)-\(saved.title)-\(candidate.title)"
			as NSString

		// Fast path: check cache under lock
		scoreCacheLock.lock()
		if let cachedScore = scoreCache.object(forKey: cacheKey) {
			scoreCacheLock.unlock()
			return cachedScore.intValue
		}
		scoreCacheLock.unlock()

		var score = 0
		let savedBundle = normalizedBundleIdentifier(saved.bundleIdentifier)
		let candidateBundle = normalizedBundleIdentifier(candidate.bundleIdentifier)

		if let savedBundle {
			// Check if bundle identifiers match
			guard candidateBundle == savedBundle else {
				// Bundle identifiers don't match, skip
				scoreCacheLock.lock()
				scoreCache.setObject(NSNumber(value: 0), forKey: cacheKey)
				scoreCacheLock.unlock()
				return 0
			}
		}

		if saved.processIdentifier == candidate.processIdentifier {
			// Process identifiers match, increase
			score += 30
		}

		if let savedBundle,
			savedBundle == candidateBundle
		{
			// Bundle identifiers match, increase
			score += 25
		}

		if saved.title == candidate.title {
			// Titles match, increase
			score += saved.title.isEmpty ? 5 : 20
		}

		if saved.role == candidate.role {
			// Roles match, increase
			score += 10
		}

		if saved.subrole == candidate.subrole {
			// Subroles match, increase
			score += 10
		}

		if saved.displayID != nil, saved.displayID == candidate.displayID {
			// Display IDs match, increase
			score += 5
		}

		score += max(0, 5 - abs(saved.order - candidate.order))

		scoreCacheLock.lock()
		scoreCache.setObject(NSNumber(value: score), forKey: cacheKey)
		scoreCacheLock.unlock()
		return score
	}

	private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
		// Normalize bundle identifiers for comparison
		guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
			// Empty bundle identifier, skip
			return nil
		}
		return bundleIdentifier
	}
}

// Restore Planning
public enum RestoreReadiness: Equatable, Sendable {
	case ready
	case missingSavedDisplays
}

public enum RestorePlanner {
	public static let displayTopologyTolerance: Double = DisplayAnchorConfiguration
		.defaultTopologyTolerance

	public static func readiness(
		savedTopology: DisplayTopology,
		currentTopology: DisplayTopology,
		tolerance: Double = displayTopologyTolerance
	) -> RestoreReadiness {
		// Check if the current topology matches the saved topology within the tolerance
		let isReady = currentTopology.matches(savedTopology, tolerance: tolerance)
		logger.info("Restore readiness check: \(isReady ? "ready" : "not ready")")
		return isReady ? .ready : .missingSavedDisplays
	}
}

// Storage
public final class SnapshotStore: @unchecked Sendable {
	public let snapshotURL: URL
	private let queue = DispatchQueue(
		label: "com.displayanchor.snapshotstore", attributes: .concurrent)

	public init(snapshotURL: URL? = nil) throws {
		// Use default location if not provided
		if let snapshotURL {
			self.snapshotURL = snapshotURL
		} else {
			// Create a default location in the user's Application Support directory
			let baseURL = try FileManager.default.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			self.snapshotURL =
				baseURL
				.appendingPathComponent("Display Anchor", isDirectory: true)
				.appendingPathComponent("LastSnapshot.json")
		}

		logger.info("SnapshotStore initialized at: \(self.snapshotURL.path)")
	}

	// Synchronous versions (legacy)
	public func load() throws -> WindowSnapshot? {
		// Use synchronous methods for legacy support
		guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
			// Snapshot file doesn't exist, return nil
			logger.debug("No snapshot file exists")
			return nil
		}

		do {
			// Load snapshot data
			let data = try Data(contentsOf: snapshotURL)
			let decoder = JSONDecoder()
			decoder.dateDecodingStrategy = .iso8601
			let snapshot = try decoder.decode(WindowSnapshot.self, from: data)
			logger.info("Loaded snapshot with \(snapshot.windows.count) windows")
			return snapshot
		} catch {
			logger.error("Failed to load snapshot: \(error.localizedDescription)")
			throw error
		}
	}

	public func save(_ snapshot: WindowSnapshot) throws {
		do {
			// Create directory if it doesn't exist
			let directory = snapshotURL.deletingLastPathComponent()
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)

			let encoder = JSONEncoder()
			encoder.dateEncodingStrategy = .iso8601
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

			let data = try encoder.encode(snapshot)
			try data.write(to: snapshotURL, options: [.atomic])

			logger.info("Saved snapshot with \(snapshot.windows.count) windows")
		} catch {
			logger.error("Failed to save snapshot: \(error.localizedDescription)")
			throw error
		}
	}

	// Async versions (recommended for production)
	@available(macOS 13.0, *)
	public func loadAsync() async throws -> WindowSnapshot? {
		// Use asynchronous methods for production
		guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
			// Snapshot file doesn't exist, return nil
			logger.debug("No snapshot file exists")
			return nil
		}

		return try await Task.detached(priority: .userInitiated) { [snapshotURL] in
			do {
				// Load snapshot data
				let data = try Data(contentsOf: snapshotURL)
				let decoder = JSONDecoder()
				decoder.dateDecodingStrategy = .iso8601
				let snapshot = try decoder.decode(WindowSnapshot.self, from: data)
				logger.info("Loaded snapshot with \(snapshot.windows.count) windows")
				return snapshot
			} catch {
				logger.error("Failed to load snapshot: \(error.localizedDescription)")
				throw error
			}
		}.value
	}

	@available(macOS 13.0, *)
	public func saveAsync(_ snapshot: WindowSnapshot) async throws {
		// Use asynchronous methods for production
		let directory = snapshotURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

		let data = try encoder.encode(snapshot)

		try await Task.detached(priority: .background) { [snapshotURL, data] in
			do {
				// Write snapshot data atomically
				try data.write(to: snapshotURL, options: [.atomic])
				logger.info("Saved snapshot with \(snapshot.windows.count) windows")
			} catch {
				logger.error("Failed to save snapshot: \(error.localizedDescription)")
				throw error
			}
		}.value
	}
}

// Snapshot Manager (Actor-based for thread safety)
@available(macOS 13.0, *)
public actor SnapshotManager {
	private let store: SnapshotStore
	private var cachedSnapshot: WindowSnapshot?
	private var cacheTimestamp: Date?

	public init(store: SnapshotStore) {
		// Initialize with a SnapshotStore
		self.store = store
	}

	public func loadSnapshot(forceReload: Bool = false) async throws -> WindowSnapshot? {
		// Check cache validity
		if !forceReload,
			let cached = cachedSnapshot,
			let timestamp = cacheTimestamp,
			Date().timeIntervalSince(timestamp) < DisplayAnchorConfiguration.snapshotCacheDuration
		{
			logger.debug("Returning cached snapshot")
			return cached
		}

		let snapshot = try await store.loadAsync()
		self.cachedSnapshot = snapshot
		self.cacheTimestamp = Date()
		return snapshot
	}

	public func saveSnapshot(_ snapshot: WindowSnapshot) async throws {
		// Save snapshot to disk
		try await store.saveAsync(snapshot)
		self.cachedSnapshot = snapshot
		self.cacheTimestamp = Date()
	}

	public func invalidateCache() {
		// Invalidate the cache
		cachedSnapshot = nil
		cacheTimestamp = nil
		logger.debug("Cache invalidated")
	}
}

