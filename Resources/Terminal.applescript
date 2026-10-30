-- Opens a new Terminal window in theDir and runs theCommand there (ADR-001 §7.3, F14).
-- HeadsUp compiles this file as it is and calls the handler with both values as Apple event
-- parameters, so they are data, never part of this script's source. theDir is an absolute path.
-- The typed line starts with a space, so a shell set to ignore such lines (zsh HIST_IGNORE_SPACE,
-- bash HISTCONTROL=ignorespace) keeps it out of its history.
on run_in_terminal(theDir, theCommand)
	tell application id "com.apple.Terminal"
		activate
		do script " cd " & quoted form of theDir & " && " & theCommand
	end tell
end run_in_terminal
