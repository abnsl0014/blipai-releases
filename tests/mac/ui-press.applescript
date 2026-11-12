-- Presses the first button whose name or description contains LABEL, in any window of
-- an Electron app (Chromium's accessibility tree is turned on first), like a click.
-- Usage: osascript tests/mac/ui-press.applescript Blip-AI "Retry"
on run argv
	set procName to item 1 of argv
	set label to item 2 of argv
	with timeout of 60 seconds
		tell application "System Events"
			tell process procName
				try
					set value of attribute "AXManualAccessibility" to true
				end try
				delay 1
				repeat with w in windows
					try
						set els to entire contents of w
						repeat with e in els
							try
								if role of e is "AXButton" then
									set n to ""
									try
										set n to name of e as text
									end try
									set d to ""
									try
										set d to description of e as text
									end try
									if n contains label or d contains label then
										perform action "AXPress" of e
										return "pressed \"" & n & "\" in " & (name of w as text)
									end if
								end if
							end try
						end repeat
					end try
				end repeat
			end tell
		end tell
	end timeout
	error "no button \"" & label & "\" in " & procName
end run
