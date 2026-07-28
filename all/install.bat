@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Suerte Open - Installer
cd /d "%~dp0"

REM ================= Configuration =================
set "SCRIPT_DIR=%~dp0"
set "SUERTE_DIR=%LOCALAPPDATA%\Suerte"
set "REPO_DIR=%SUERTE_DIR%\suerte_open"
set "REPO_URL=https://github.com/neggacoder/suerte_open"
set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
REM The server is started by pythonw.exe (GUI subsystem: no console window is
REM created at all). A .bat in the Startup folder would always flash a cmd
REM window, so autostart is a .lnk pointing straight at pythonw.exe.
set "RUN_PY=%REPO_DIR%\run_server.py"
set "STOP_BAT=%SCRIPT_DIR%stop_server.bat"
set "SERVER_LOG=%SUERTE_DIR%\server.log"
set "STARTUP_LNK=%STARTUP_DIR%\Suerte Server.lnk"
set "LEGACY_STARTUP_BAT=%STARTUP_DIR%\run_server.bat"
set "LEGACY_RUN_BAT=%SCRIPT_DIR%run_server.bat"
set "PYW="
set "TESS_DIR=%ProgramFiles%\Tesseract-OCR"
set "TESSDATA_DIR=%TESS_DIR%\tessdata"
set "TESSDATA_BASE=https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/main"
set "PY_VER=3.12.10"
set "PY_URL=https://www.python.org/ftp/python/%PY_VER%/python-%PY_VER%-amd64.exe"
set "TESS_URL=https://github.com/UB-Mannheim/tesseract/releases/download/v5.4.0.20240606/tesseract-ocr-w64-setup-5.4.0.20240606.exe"
set "ADMIN_LOG=%SCRIPT_DIR%suerte_admin.log"
set "PYEXE="

REM Elevated re-entry: run ONLY the admin phase, then exit.
if /I "%~1"=="ADMINPHASE" goto :admin_phase

echo ============================================================
echo   Suerte Open - Automated Installer
echo   Target: clean Windows 10/11 x64. Internet required.
echo   Python/Git/repo run without admin; only Tesseract/Git
echo   installation asks for admin once (a single UAC prompt).
echo ============================================================
echo.

call :ensure_curl        || goto :fail
call :ensure_python      || goto :fail
call :ensure_git_tess    || goto :fail
call :ensure_dirs        || goto :fail
call :clone_or_pull      || goto :fail
call :setup_venv         || goto :fail
call :install_reqs       || goto :fail
call :create_run_script  || goto :fail
call :install_autostart
call :start_server

echo.
echo ============================================================
echo   Installation completed successfully.
echo.
echo   Server is available at:
echo   http://127.0.0.1:8000
echo.
echo   It runs hidden, without a console window, and starts on logon.
echo   Log:  %SERVER_LOG%
echo   Stop: %STOP_BAT%
echo ============================================================
echo.
echo This window will stay open so you can read the log above.
pause
endlocal
exit /b 0

:fail
echo.
echo [ERROR] Installation failed. Read the messages above.
echo This window will stay open so you can read the error.
pause
endlocal
exit /b 1


REM ============================================================
REM  Logging helpers
REM ============================================================
:log_info
echo [INFO] %~1
exit /b 0
:log_ok
echo [OK] %~1
exit /b 0
:log_warn
echo [WARNING] %~1
exit /b 0
:log_err
echo [ERROR] %~1
exit /b 0


REM ============================================================
REM  Refresh PATH from the registry (after installers)
REM ============================================================
:refresh_path
set "SYSPATH="
set "USERPATH="
for /f "skip=2 tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYSPATH=%%B"
for /f "skip=2 tokens=2,*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USERPATH=%%B"
set "PATH=%SYSPATH%;%USERPATH%"
exit /b 0


REM ============================================================
REM  Step 0: curl (ships with Windows 10 1803+ / 11)
REM ============================================================
:ensure_curl
where curl >nul 2>&1
if errorlevel 1 (
    call :log_err "curl.exe not found. Update Windows 10/11 or install curl manually."
    exit /b 1
)
call :log_ok "curl is available."
exit /b 0


REM ============================================================
REM  Step 2: Python 3.12 x64 (per-user, no admin)
REM ============================================================
:ensure_python
call :log_info "Checking Python..."
call :locate_python
if defined PYEXE (
    call :log_ok "Python already installed: !PYEXE!"
    goto :ensure_python_pip
)

call :log_warn "Python not found. Installing Python %PY_VER% x64 (per-user)..."
where winget >nul 2>&1
if not errorlevel 1 (
    call :log_info "Installing Python via winget (user scope)..."
    winget install --id Python.Python.3.12 -e --source winget --scope user --accept-package-agreements --accept-source-agreements --silent
)
call :locate_python
if defined PYEXE goto :ensure_python_verify

call :log_warn "winget unavailable or failed. Using official python.org installer..."
call :log_info "Downloading Python %PY_VER%..."
curl -L --fail --retry 3 -o "%TEMP%\python-setup.exe" "%PY_URL%"
if not exist "%TEMP%\python-setup.exe" (
    call :log_err "Failed to download Python installer."
    exit /b 1
)
call :log_info "Installing Python silently (per-user)..."
"%TEMP%\python-setup.exe" /quiet InstallAllUsers=0 PrependPath=1 Include_pip=1 Include_launcher=1 Include_test=0
call :locate_python

:ensure_python_verify
if not defined PYEXE (
    call :log_err "Python installation could not be verified. Restart the PC and re-run this script."
    exit /b 1
)
call :log_ok "Python ready: !PYEXE!"

:ensure_python_pip
"!PYEXE!" -m ensurepip --upgrade >nul 2>&1
call :log_ok "pip is available."
exit /b 0

:locate_python
if defined PYEXE exit /b 0
py -3 -c "import sys" >nul 2>nul
if not errorlevel 1 for /f "delims=" %%p in ('py -3 -c "import sys;print(sys.executable)"') do set "PYEXE=%%p"
if not defined PYEXE (
    python -c "import sys" >nul 2>nul
    if not errorlevel 1 for /f "delims=" %%p in ('python -c "import sys;print(sys.executable)"') do set "PYEXE=%%p"
)
if not defined PYEXE (
    for /d %%d in ("%LOCALAPPDATA%\Programs\Python\Python3*") do if exist "%%d\python.exe" set "PYEXE=%%d\python.exe"
)
exit /b 0


REM ============================================================
REM  Steps 1 + 3: Git and Tesseract (need admin -> one UAC)
REM ============================================================
:ensure_git_tess
call :log_info "Checking Git, Tesseract and language data..."
set "NEED_ADMIN="
where git >nul 2>&1
if errorlevel 1 set "NEED_ADMIN=1"
if not exist "%TESS_DIR%\tesseract.exe" set "NEED_ADMIN=1"
if not exist "%TESSDATA_DIR%\eng.traineddata" set "NEED_ADMIN=1"
if not exist "%TESSDATA_DIR%\rus.traineddata" set "NEED_ADMIN=1"
if not exist "%TESSDATA_DIR%\kaz.traineddata" set "NEED_ADMIN=1"
if not defined NEED_ADMIN (
    call :log_ok "Git, Tesseract and language data are already present."
    exit /b 0
)

del "%ADMIN_LOG%" >nul 2>&1
call :log_info "Some components need administrator rights (Git and/or Tesseract)."
call :log_info "A UAC prompt will appear now - please click Yes."
powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -ArgumentList 'ADMINPHASE' -Verb RunAs -Wait } catch { exit 1 }"

if exist "%ADMIN_LOG%" (
    echo ------------------- admin phase log -------------------
    type "%ADMIN_LOG%"
    echo -------------------------------------------------------
)

call :refresh_path
set "PATH=%PATH%;%ProgramFiles%\Git\cmd;%TESS_DIR%"

where git >nul 2>&1
if errorlevel 1 (
    if not exist "%ProgramFiles%\Git\cmd\git.exe" (
        call :log_err "Git is still not available and is required to continue."
        call :log_err "Install Git manually and re-run this script."
        exit /b 1
    )
    set "PATH=%PATH%;%ProgramFiles%\Git\cmd"
)
call :log_ok "Git is available."

if exist "%TESS_DIR%\tesseract.exe" (
    call :log_ok "Tesseract is installed."
) else (
    call :log_warn "Tesseract is not installed. The app will run, but OCR will be unavailable."
)
exit /b 0


REM ============================================================
REM  Step 4: Directories
REM ============================================================
:ensure_dirs
if not exist "%SUERTE_DIR%" (
    call :log_info "Creating %SUERTE_DIR%..."
    mkdir "%SUERTE_DIR%"
    if errorlevel 1 (
        call :log_err "Could not create %SUERTE_DIR%."
        exit /b 1
    )
    call :log_ok "Directory created."
) else (
    call :log_ok "Directory %SUERTE_DIR% already exists."
)
exit /b 0


REM ============================================================
REM  Step 5-6: Clone or pull repository
REM ============================================================
:clone_or_pull
if exist "%REPO_DIR%\.git" (
    call :log_info "Repository exists. Pulling latest changes..."
    pushd "%REPO_DIR%"
    git pull
    set "GIT_RC=!errorlevel!"
    popd
    if not "!GIT_RC!"=="0" (
        call :log_warn "git pull failed. Continuing with the existing copy."
    ) else (
        call :log_ok "Repository updated."
    )
) else (
    call :log_info "Cloning %REPO_URL%..."
    git clone "%REPO_URL%" "%REPO_DIR%"
    if errorlevel 1 (
        call :log_err "git clone failed."
        exit /b 1
    )
    call :log_ok "Repository cloned."
)
exit /b 0


REM ============================================================
REM  Step 7: Virtual environment
REM ============================================================
:setup_venv
pushd "%REPO_DIR%"
if exist "venv\Scripts\python.exe" (
    call :log_ok "Virtual environment already exists."
    popd
    exit /b 0
)
call :log_info "Creating virtual environment..."
"%PYEXE%" -m venv venv
if not exist "venv\Scripts\python.exe" (
    call :log_err "Failed to create virtual environment."
    popd
    exit /b 1
)
call :log_ok "Virtual environment created."
popd
exit /b 0


REM ============================================================
REM  Steps 8-10: pip, dependencies, uvicorn
REM ============================================================
:install_reqs
pushd "%REPO_DIR%"

call :log_info "Upgrading pip..."
"venv\Scripts\python.exe" -m pip install --upgrade pip
if errorlevel 1 (
    call :log_err "Failed to upgrade pip."
    popd
    exit /b 1
)
call :log_ok "pip upgraded."

if exist "vox_server\requirements.txt" (
    call :log_info "Installing dependencies from vox_server\requirements.txt..."
    "venv\Scripts\python.exe" -m pip install -r "vox_server\requirements.txt"
    if errorlevel 1 (
        call :log_err "Failed to install dependencies."
        popd
        exit /b 1
    )
    call :log_ok "Dependencies installed."
) else (
    call :log_warn "vox_server\requirements.txt not found. Skipping."
)

call :log_info "Installing Playwright Chromium (for /scan-dynamic)..."
"venv\Scripts\python.exe" -m playwright install chromium
if errorlevel 1 (
    call :log_warn "Playwright Chromium install failed. /scan-dynamic will fall back to generic scan."
) else (
    call :log_ok "Playwright Chromium installed."
)

"venv\Scripts\python.exe" -m pip show uvicorn >nul 2>&1
if errorlevel 1 (
    call :log_info "Installing uvicorn..."
    "venv\Scripts\python.exe" -m pip install uvicorn
    if errorlevel 1 (
        call :log_err "Failed to install uvicorn."
        popd
        exit /b 1
    )
    call :log_ok "uvicorn installed."
) else (
    call :log_ok "uvicorn is already installed."
)

popd
exit /b 0


REM ============================================================
REM  Step 11: run_server.py (launcher) + stop_server.bat
REM ============================================================
REM  run_server.py replaces the old run_server.bat. It is launched by
REM  pythonw.exe, which belongs to the GUI subsystem and therefore never
REM  allocates a console: no window, no taskbar button, nothing to close by
REM  accident. The price is that pythonw gives the process no stdout/stderr
REM  (sys.stdout is None), so uvicorn's log records would be silently dropped
REM  -- the launcher redirects both streams to a file before uvicorn sets up
REM  logging. It also picks up Tesseract before importing the app, because
REM  vox_server.load_config() reads TESSERACT_CMD at import time.
REM
REM  Every echoed line must avoid the characters cmd treats as operators
REM  (redirection, pipe, ampersand, percent) and must not rely on indentation:
REM  "echo" eats exactly one leading space. Hence the flat, one-liner Python.
:create_run_script
call :log_info "Creating run_server.py..."
> "%RUN_PY%" echo # Generated by install.bat. Launched by pythonw.exe: no console window.
>> "%RUN_PY%" echo import os, sys, pathlib
>> "%RUN_PY%" echo.
>> "%RUN_PY%" echo BASE = pathlib.Path(__file__).resolve().parent
>> "%RUN_PY%" echo os.chdir(BASE)
>> "%RUN_PY%" echo sys.path.insert(0, str(BASE))
>> "%RUN_PY%" echo.
>> "%RUN_PY%" echo # pythonw.exe has no stdout/stderr; send uvicorn's log to a file instead.
>> "%RUN_PY%" echo LOG = BASE.parent / "server.log"
>> "%RUN_PY%" echo _f = open(str(LOG), "w", buffering=1, encoding="utf-8", errors="replace")
>> "%RUN_PY%" echo sys.stdout = _f
>> "%RUN_PY%" echo sys.stderr = _f
>> "%RUN_PY%" echo.
>> "%RUN_PY%" echo # load_config() reads TESSERACT_CMD at import time, so set it first.
>> "%RUN_PY%" echo _c = [os.path.join(os.environ.get("ProgramFiles", ""), "Tesseract-OCR", "tesseract.exe"), os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Tesseract-OCR", "tesseract.exe")]
>> "%RUN_PY%" echo _hit = [p for p in _c if os.path.exists(p)]
>> "%RUN_PY%" echo if _hit: os.environ.setdefault("TESSERACT_CMD", _hit[0])
>> "%RUN_PY%" echo.
>> "%RUN_PY%" echo import uvicorn
>> "%RUN_PY%" echo from vox_server.vox_server import app, CONFIG
>> "%RUN_PY%" echo.
>> "%RUN_PY%" echo uvicorn.run(app, host=CONFIG["host"], port=int(CONFIG["port"]), log_level="info")
if not exist "%RUN_PY%" (
    call :log_err "Failed to create run_server.py."
    exit /b 1
)
call :log_ok "run_server.py created."

REM pythonw.exe ships with every CPython venv on Windows; degrade loudly if not.
set "PYW=%REPO_DIR%\venv\Scripts\pythonw.exe"
if not exist "%PYW%" (
    call :log_warn "pythonw.exe not found in the venv. The server will run with a visible console window."
    set "PYW=%REPO_DIR%\venv\Scripts\python.exe"
)

REM A hidden server cannot be stopped with Ctrl+C, so ship an off switch.
call :log_info "Creating stop_server.bat..."
> "%STOP_BAT%" echo @echo off
REM The pipes need no "^" escape: they sit inside double quotes, where cmd
REM does not treat them as operators (a "^|" would be echoed verbatim).
>> "%STOP_BAT%" echo powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'pythonw.exe' -and $_.CommandLine -like '*run_server.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
>> "%STOP_BAT%" echo echo Suerte server stopped.
call :log_ok "stop_server.bat created."

REM The old launcher must go: left in Startup it would race this one for port 8000.
del "%LEGACY_RUN_BAT%" >nul 2>&1
exit /b 0


REM ============================================================
REM  Step 12: Autostart
REM ============================================================
:install_autostart
call :log_info "Updating autostart entry..."
REM Drop the pre-existing .bat entry: a .bat in Startup always opens a console,
REM and two launchers would fight over port 8000.
del "%LEGACY_STARTUP_BAT%" >nul 2>&1
REM Arguments stay relative and WorkingDirectory carries the path, so a user
REM name with spaces never has to be quoted inside the PowerShell command.
powershell -NoProfile -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('%STARTUP_LNK%'); $s.TargetPath = '%PYW%'; $s.Arguments = 'run_server.py'; $s.WorkingDirectory = '%REPO_DIR%'; $s.WindowStyle = 7; $s.Description = 'Suerte local server'; $s.Save()"
if exist "%STARTUP_LNK%" (
    call :log_ok "Autostart entry is up to date."
) else (
    call :log_warn "Could not create autostart entry. Continuing without autostart."
)
exit /b 0


REM ============================================================
REM  Step 13: Start the server
REM ============================================================
REM  "start" on a GUI-subsystem exe (pythonw) creates no console; run_server.py
REM  chdir's to its own folder, so no /D is needed here.
:start_server
call :log_info "Starting server (hidden, no console window)..."
start "" "%PYW%" "%RUN_PY%"
call :log_ok "Server launched."
exit /b 0


REM ============================================================
REM  Admin phase (runs elevated via re-entry: install.bat ADMINPHASE)
REM  All output is written to ADMIN_LOG and shown by the main window.
REM ============================================================
:admin_phase
> "%ADMIN_LOG%" echo [ADMIN] Admin phase started.
call :admin_git
call :admin_tess
call :admin_langs
>> "%ADMIN_LOG%" echo [ADMIN] Admin phase finished.
endlocal
exit /b 0

:admin_git
set "GIT_PRESENT="
where git >nul 2>&1 && set "GIT_PRESENT=1"
if exist "%ProgramFiles%\Git\cmd\git.exe" set "GIT_PRESENT=1"
if defined GIT_PRESENT ( >> "%ADMIN_LOG%" echo [ADMIN] Git already installed. & exit /b 0 )
>> "%ADMIN_LOG%" echo [ADMIN] Installing Git...
where winget >nul 2>&1 && winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements --silent >> "%ADMIN_LOG%" 2>&1
if exist "%ProgramFiles%\Git\cmd\git.exe" ( >> "%ADMIN_LOG%" echo [ADMIN] Git installed via winget. & exit /b 0 )
>> "%ADMIN_LOG%" echo [ADMIN] Downloading official Git installer...
set "GIT_URL="
for /f "usebackq delims=" %%U in (`powershell -NoProfile -Command "try { (Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest').assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1 -ExpandProperty browser_download_url } catch { '' }"`) do set "GIT_URL=%%U"
if not defined GIT_URL ( >> "%ADMIN_LOG%" echo [ADMIN] ERROR: could not resolve Git download URL. & exit /b 0 )
curl -L --fail --retry 3 -o "%TEMP%\git-setup.exe" "%GIT_URL%" >> "%ADMIN_LOG%" 2>&1
if exist "%TEMP%\git-setup.exe" "%TEMP%\git-setup.exe" /VERYSILENT /NORESTART /SUPPRESSMSGBOXES >> "%ADMIN_LOG%" 2>&1
exit /b 0

:admin_tess
if exist "%TESS_DIR%\tesseract.exe" ( >> "%ADMIN_LOG%" echo [ADMIN] Tesseract already installed. & exit /b 0 )
>> "%ADMIN_LOG%" echo [ADMIN] Installing Tesseract...
where winget >nul 2>&1 && winget install --id UB-Mannheim.TesseractOCR -e --source winget --accept-package-agreements --accept-source-agreements --silent >> "%ADMIN_LOG%" 2>&1
if exist "%TESS_DIR%\tesseract.exe" ( >> "%ADMIN_LOG%" echo [ADMIN] Tesseract installed via winget. & exit /b 0 )
>> "%ADMIN_LOG%" echo [ADMIN] Downloading official Tesseract installer...
curl -L --fail --retry 3 -o "%TEMP%\tesseract-setup.exe" "%TESS_URL%" >> "%ADMIN_LOG%" 2>&1
if exist "%TEMP%\tesseract-setup.exe" "%TEMP%\tesseract-setup.exe" /S >> "%ADMIN_LOG%" 2>&1
exit /b 0

:admin_langs
if not exist "%TESS_DIR%\tesseract.exe" ( >> "%ADMIN_LOG%" echo [ADMIN] Skipping language data - Tesseract not installed. & exit /b 0 )
if not exist "%TESSDATA_DIR%" mkdir "%TESSDATA_DIR%" >> "%ADMIN_LOG%" 2>&1
call :admin_one_lang eng
call :admin_one_lang rus
call :admin_one_lang kaz
exit /b 0

:admin_one_lang
if exist "%TESSDATA_DIR%\%~1.traineddata" ( >> "%ADMIN_LOG%" echo [ADMIN] Language %~1 already present. & exit /b 0 )
>> "%ADMIN_LOG%" echo [ADMIN] Downloading language %~1...
curl -L --fail --retry 3 -o "%TESSDATA_DIR%\%~1.traineddata" "%TESSDATA_BASE%/%~1.traineddata" >> "%ADMIN_LOG%" 2>&1
exit /b 0
