-- Prints the visible text of every window of an Electron app, one line per element,
-- by turning on Chromium's accessibility tree (AXManualAccessibility) and walking it.
-- Usage: osascript tests/mac/ui-text.applescript Blip-AI
on run argv
	set procName to item 1 of argv
	set out to ""
	with timeout of 90 seconds
		tell application "System Events"
			tell process procName
				try
					set value of attribute "AXManualAccessibility" to true
				end try
				delay 2
				repeat with w in windows
					try
						set out to out & "== window: " & (name of w as text) & linefeed
					end try
					try
						set els to entire contents of w
						repeat with e in els
							set t to ""
							try
								set v to value of e
								if class of v is text then set t to v
							end try
							if t is "" then
								try
									set n to name of e
									if n is not missing value then set t to n as text
								end try
							end if
							if t is not "" then set out to out & t & linefeed
						end repeat
					end try
				end repeat
			end tell
		end tell
	end timeout
	return out
end run
