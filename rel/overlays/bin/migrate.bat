call "%~dp0\scrawly" eval Scrawly.Release.migrate || exit /b 1
call "%~dp0\scrawly" eval Scrawly.Release.sync_words
