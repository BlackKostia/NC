# Optional VHS tape for recording an animated GIF demo of Duop (https://github.com/charmbracelet/vhs)
# Run from the repository root after `make release`:
#   vhs docs/media/demo.tape
Output docs/media/demo.gif
Set FontSize 14
Set Width 1100
Set Height 620
Set Theme "TokyoNight"
Set Padding 12

Hide
Type "./duop --lang en"
Enter
Sleep 1s
Show

Sleep 1.2s
Down
Down
Sleep 500ms
# Toggle Live Preview (F9)
F9
Sleep 1.5s
# Open Command Palette (Ctrl+K)
Ctrl+K
Sleep 1s
Type "Theme"
Sleep 800ms
Enter
Sleep 1.2s
# Switch interface language (Alt+L)
Alt+l
Sleep 1.5s
Alt+l
Sleep 1s
# Quit (F10)
F10
