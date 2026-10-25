-- Opens a new iTerm2 window in theDir and runs theCommand there (ADR-001 §7.3, F14).
-- HeadsUp compiles this file as it is and calls the handler with both values as Apple event
-- parameters, so they are data, never part of this script's source. theDir is an absolute path.
on run_in_terminal(theDir, theCommand)
	tell application id "com.googlecode.iterm2"
		activate
		set newWindow to (create window with default profile)
		tell current session of newWindow
			write text "cd " & quoted form of theDir & " && " & theCommand
		end tell
	end tell
end run_in_terminal
