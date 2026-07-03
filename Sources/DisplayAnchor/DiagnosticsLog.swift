import Foundation

final class DiagnosticsLog {
	/// Maximum size (in bytes) of the log file before rotation.
	/// Set to 256 KB to balance retention and performance.
	private let maxLogBytes: Int = 256_000

	/// URL to the log file. `nil` if initialization failed.
	private let logURL: URL?

	/// Serial queue to ensure thread-safe access to the log file.
	private let serialQueue = DispatchQueue(label: "com.yourapp.diagnostics.log", qos: .background)

	/// Initializes the logger and creates the necessary directory structure.
	///
	/// The log file is stored in:
	/// `~/Library/Application Support/Display Anchor/Events.log`
	///
	/// If directory creation or file access fails, the logger will silently disable logging.
	///
	/// - Returns: An initialized `DiagnosticsLog` instance.
	init() {
		do {
			// Get the application support directory
			let baseURL = try FileManager.default.url(
				for: .applicationSupportDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)

			// Create a subdirectory named "Display Anchor"
			let directory = baseURL.appendingPathComponent("Display Anchor", isDirectory: true)
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true, attributes: nil)

			// Define the log file path
			logURL = directory.appendingPathComponent("Events.log")

		} catch {
			// On failure, disable logging by setting logURL to nil
			logURL = nil
		}
	}

	/// Writes a message to the log file with a timestamp.
	///
	/// This method is thread-safe and will not block the calling thread.
	///
	/// - Parameter message: The string to write to the log.
	///
	/// - Returns: `true` if the message was successfully written, `false` otherwise.
	func write(_ message: String) -> Bool {
		// Early exit if logging is disabled
		guard let url = logURL else { return false }

		let maxBytes = self.maxLogBytes

		// Perform all file operations on a background queue to avoid blocking
		serialQueue.async { [url, maxBytes, message] in
			do {
				// Check if the log file exists and exceeds the maximum size
				if FileManager.default.fileExists(atPath: url.path) {
					if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
						let size = attributes[.size] as? NSNumber,
						size.intValue > maxBytes
					{
						// Rotate the log: truncate the file atomically
						try Data().write(to: url, options: [.atomic])
					}
				}

				// Format the message with a timestamp
				let line = "\(Self.format(Date())) \(message)\n"
				let data = Data(line.utf8)

				// Open the file for writing (append mode)
				if FileManager.default.fileExists(atPath: url.path) {
					let handle = try FileHandle(forWritingTo: url)
					try handle.seekToEnd()
					try handle.write(contentsOf: data)
					try handle.close()
				} else {
					// If the file doesn't exist, write it atomically
					try data.write(to: url, options: [.atomic])
				}

			} catch {
				// Log errors are non-critical; ignore them to maintain stability
				// In production, consider sending this to a crash reporter or analytics service
				return
			}
		}

		return true
	}

	// Private Helpers

	/// Formats a `Date` into an ISO 8601 string with fractional seconds.
	///
	/// Example: `2025-04-05T14:30:45.123Z`
	///
	/// - Parameter date: The date to format.
	/// - Returns: A formatted string representation of the date.
	private static func format(_ date: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter.string(from: date)
	}
}
