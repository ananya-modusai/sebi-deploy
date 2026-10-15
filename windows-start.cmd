@echo off
setlocal enabledelayedexpansion
REM ===========================================================================
REM  Modus surveillance - ONE SHOT start on a Windows machine (Docker Desktop)
REM
REM    Double-click this file, or:  windows-start.cmd
REM
REM  Starts both containers, waits for the database to load, checks everything,
REM  and tells you the one URL to open. Safe to run again - it reuses the data
REM  instead of reloading it.
REM
REM  This is for TESTING on Windows. The RHEL VMs use deploy-db.sh / deploy-app.sh.
REM ===========================================================================

set "APP_IMAGE=olamzar/modus-app:2.4"
set "DB_IMAGE=olamzar/modus-db:1.3"
set "PORT=3000"
set "LOG=%TEMP%\modus-start.log"

echo. > "%LOG%"
echo ===========================================================
echo  MODUS - starting up. This takes 10-15 minutes the first
echo  time (4 GB of images). Leave the window open.
echo ===========================================================
echo.

REM ---------------------------------------------------------------- 1. docker?
echo [1/7] Checking Docker...
docker version >nul 2>&1
if errorlevel 1 (
  echo       FAILED - Docker is not running.
  echo       Start Docker Desktop, wait for the whale icon to go steady, run this again.
  goto :fail
)
echo       OK

REM ---------------------------------------------------------------- 2. images
echo [2/7] Downloading images ^(the long part - be patient^)...
docker image inspect %DB_IMAGE% >nul 2>&1
if errorlevel 1 (
  echo       pulling database image...
  docker pull %DB_IMAGE% >>"%LOG%" 2>&1
  if errorlevel 1 echo       FAILED to pull %DB_IMAGE% & goto :fail
) else ( echo       database image already here )

docker image inspect %APP_IMAGE% >nul 2>&1
if errorlevel 1 (
  echo       pulling application image ^(about 4 GB^)...
  docker pull %APP_IMAGE% >>"%LOG%" 2>&1
  if errorlevel 1 echo       FAILED to pull %APP_IMAGE% & goto :fail
) else ( echo       application image already here )
echo       OK

REM ---------------------------------------------------------------- 3. network
echo [3/7] Network and storage...
docker network create modus >nul 2>&1
docker volume create modus_pgdata >nul 2>&1
docker volume create modus_blobs  >nul 2>&1
echo       OK

REM ---------------------------------------------------------------- 4. database
echo [4/7] Starting the database...
docker rm -f modus-db >nul 2>&1
docker run -d --name modus-db --network modus -p 5432:5432 ^
  -v modus_pgdata:/var/lib/postgresql/data ^
  %DB_IMAGE% >>"%LOG%" 2>&1
if errorlevel 1 echo       FAILED to start the database & goto :fail
echo       started

REM ---------------------------------------------------------------- 5. wait
echo [5/7] Loading data ^(up to 5 minutes the first time^)...
set "COMPANIES=0"
for /l %%i in (1,1,60) do (
  timeout /t 6 /nobreak >nul
  docker exec modus-db psql -U modus -d surveillance -tAc "SELECT count(*) FROM surveillance_sebi.companies" > "%TEMP%\mc.txt" 2>nul
  set /p C=<"%TEMP%\mc.txt"
  set "C=!C: =!"
  if defined C (
    if !C! GTR 0 (
      set "COMPANIES=!C!"
      echo       loaded - !C! companies
      goto :dbready
    )
  )
  echo       still loading... ^(%%i of 60^)
)
echo       FAILED - the database never finished loading.
echo       Run:  docker logs modus-db
goto :fail

:dbready

REM ---------------------------------------------------------------- 6. app
echo [6/7] Starting the application...
docker rm -f modus-app >nul 2>&1
docker run -d --name modus-app --network modus -p %PORT%:8080 ^
  -v modus_blobs:/data/seaweed ^
  -e DB_HOST=modus-db ^
  -e DB_PORT=5432 ^
  -e DB_NAME=surveillance ^
  -e DB_USER=modus ^
  -e DB_PASSWORD=modus ^
  -e SSH_TUNNEL_ENABLED=false ^
  -e DEPLOY_ENV=onprem ^
  -e SURVEILLANCE_SCHEMA=surveillance_sebi ^
  -e BLOB_PUBLIC_URL=http://localhost:%PORT% ^
  -e REPORT_APP_URL=http://localhost:8080/ ^
  -e SEBI_ADMIN_EMAIL=ananya@modussecure.com ^
  %APP_IMAGE% >>"%LOG%" 2>&1
if errorlevel 1 echo       FAILED to start the application & goto :fail
echo       started

REM ---------------------------------------------------------------- 7. verify
echo [7/7] Waiting for it to answer...
set "UICODE=000"
for /l %%i in (1,1,40) do (
  timeout /t 6 /nobreak >nul
  for /f %%h in ('curl -s -o nul -w "%%{http_code}" http://localhost:%PORT%/ 2^>nul') do set "UICODE=%%h"
  if "!UICODE!"=="200" goto :appready
  echo       waiting... ^(%%i of 40, last response !UICODE!^)
)
echo       FAILED - the application never answered.
echo       Run:  docker logs modus-app
goto :fail

:appready
for /f %%h in ('curl -s -o nul -w "%%{http_code}" http://localhost:%PORT%/docs 2^>nul') do set "APICODE=%%h"
for /f %%h in ('curl -s -o nul -w "%%{http_code}" http://localhost:%PORT%/api/companies 2^>nul') do set "DATACODE=%%h"

echo.
echo ===========================================================
echo  READY
echo.
echo    Open:      http://localhost:%PORT%
echo    Sign in:   with the account and password Ananya gave you
echo.
echo    companies in database : %COMPANIES%
echo    UI                    : %UICODE%    ^(want 200^)
echo    API docs              : %APICODE%    ^(want 200^)
echo    data endpoint         : %DATACODE%    ^(401 is CORRECT - auth is working^)
echo.
echo  Once signed in, check that evidence SCREENSHOTS appear on a
echo  company's posts. If text loads but images are broken, that is
echo  the one failure that matters - tell Ananya.
echo.
echo  If anything is wrong:  windows-collect.cmd
echo ===========================================================
echo.
pause
exit /b 0

:fail
echo.
echo ===========================================================
echo  STOPPED. Nothing was damaged - you can run this again.
echo  Details were written to:
echo    %LOG%
echo  For a full diagnosis run:  windows-collect.cmd
echo ===========================================================
echo.
pause
exit /b 1
