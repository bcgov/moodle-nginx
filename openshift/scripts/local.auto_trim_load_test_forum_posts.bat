@echo off
setlocal enabledelayedexpansion

set command_to_run=oc rsh mariadb-galera-0 mysql -u root -p"%MOODLE_MYSQL_ROOT_PASSWORD%" -e "USE `moodle`; DELETE FROM forum_posts WHERE message LIKE 'I am the test plan reply message';"
set command_to_test_completion=oc rsh mariadb-galera-0 mysql -u root -p"%MOODLE_MYSQL_ROOT_PASSWORD%" -e "USE `moodle`; SELECT COUNT(*) FROM forum_posts WHERE message LIKE 'I am the test plan reply message';"

set loop_count=0
set loop_time=120

:: Loop indefinitely
:loop
  set /a loop_count+=1
  echo %loop_count%) Checking forum replies from test plan...

  @REM Check for PVC capacity issues
  @REM $ du -m /data/*
  @REM 295     /data/appendonlydir
  @REM 26      /data/dump.rdb
  @REM 47      /data/temp-rewriteaof-213312.aof

  @REM for /f "tokens=*" %%a in ('%command_to_test_completion% 2^>^&1') do (
  @REM   echo %%a
    @REM echo %%a | findstr /c:"Unauthorized" >nul
    @REM if not errorlevel 1 (
    @REM   echo Error: You are not logged in to the server. Exiting loop.
    @REM   goto end
    @REM )
  @REM )

  echo Checking for test plan reply messages...
  set count=
  for /f "skip=4 tokens=*" %%a in ('%command_to_test_completion% 2^>^&1') do (
    rem echo Output line: %%a
    rem Output all tokens for debugging
    for /f "tokens=1,2 delims=|" %%b in ("%%a") do (
      echo Token: %%b
      rem Check if the token is a numeric value
      echo %%b | findstr /r "^[ ]*[0-9][0-9]*[ ]*$" >nul
      if not errorlevel 1 (
        set count=%%b
        set count=!count: =!
        goto found_count
      )
    )
  )

:found_count
  echo Records found: !count!

  if "!count!"=="0" (
    echo No results found. Exiting loop.
    goto end
  )

  echo Deleting records...
  set error_output=
  for /f "tokens=*" %%a in ('%command_to_run% 2^>^&1') do (
    echo %%a | findstr /c:"Unauthorized" >nul
    if not errorlevel 1 (
      set error_output=%%a
    )
    echo %%a | findstr /c:"Error" >nul
    if not errorlevel 1 (
      set error_output=%%a
    )
  )

  if defined error_output (
    echo Error: !error_output!
  )

  echo Waiting for %loop_time% seconds...
  timeout /t %loop_time% >nul

  goto loop
:end

echo Done.
endlocal
