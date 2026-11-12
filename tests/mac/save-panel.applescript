-- Clicks Save in the save panel the app just opened: a sheet on one of its windows
-- (macOS 15), any of its windows with a Save button, or a window of macOS's save panel
-- service. If none shows up within 10 s, brings the app forward and presses Return,
-- and says which windows and sheets the app had.
-- Usage: osascript tests/mac/save-panel.applescript Blip-AI
-- (A file of its own: macOS's bash 3.2 can't parse this inside $( ) with a heredoc.)
on run argv
	set appName to item 1 of argv
	tell application "System Events"
		repeat 20 times
			-- the app's own windows: a sheet, or a window with a Save button
			repeat with w in (windows of process appName)
				try
					if exists sheet 1 of w then
						click button "Save" of sheet 1 of w
						return "clicked Save in a sheet of " & (name of w)
					end if
				end try
				try
					if exists button "Save" of w then
						click button "Save" of w
						return "clicked Save in the window " & (name of w)
					end if
				end try
			end repeat
			-- macOS can draw the panel from its own service process
			repeat with p in (processes whose name contains "Save Panel")
				try
					repeat with w in (windows of p)
						if exists button "Save" of w then
							click button "Save" of w
							return "clicked Save in " & (name of p)
						end if
					end repeat
				end try
			end repeat
			delay 0.5
		end repeat
		set seen to ""
		try
			repeat with w in (windows of process appName)
				set seen to seen & "'" & (name of w) & "' (" & (count of sheets of w) & " sheets) "
			end repeat
		end try
		tell process appName to set frontmost to true
		delay 0.5
		key code 36
		return "no Save button found in 10 s (windows: " & seen & "); pressed Return with Blip in front"
	end tell
end run
