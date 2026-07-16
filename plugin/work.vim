" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

""""""""""""""""""""""""""""Commit tag"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#ExtractIssue(...)
  let branch = get(a:000, 0, git#GetBranch())
  return matchstr(branch, 'SW-[0-9]\{4\}')
endfunction

function! s:OnNewCommit()
  setlocal spell
  setlocal tw=90
  setlocal cc=91

  const whitelist = map(s:GetTargets(), 'v:val[0]')
  if index(whitelist, FugitiveWorkTree()) < 0
    return
  endif

  let branch = git#GetBranch()
  if branch == 'master' || branch == 'obsidian-master' || branch == 'main'
    return init#Warn('Current branch is %s!', branch)
  endif

  let issue = work#ExtractIssue()
  if empty(getline(1)) && !empty(issue)
    call setline(1, issue .. ': ')
    startinsert!
  endif
endfunction

autocmd FileType gitcommit call s:OnNewCommit()
"}}}

""""""""""""""""""""""""""""Building"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#GetMakeCommand()
  let repo = FugitiveWorkTree()
  if repo == git#WorktreePath()
    let repo = git#WorktreeCommonPath()
  endif
  return work#GetMakeCommandFor(fnamemodify(repo, ":t"))
endfunction

function! work#GetMakeCommandFor(repo)
  if empty(a:repo)
    call init#Warn("Not inside a git tracked repo!")
  endif
  let repo = a:repo
  
  let dir = FugitiveWorkTree()
  if empty(dir)
    let dir = getcwd()
  endif

  let cmds = []
  call add(cmds, printf("cd %s", dir))
  call add(cmds, printf("source %s/environment-setup-armv8a-aisys-linux", g:SDK_DIR))

  let sdk_flags = [
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/%s/", g:SDK_DIR, g:LIBSTD_CPP),
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/%s/aarch64-aisys-linux", g:SDK_DIR, g:LIBSTD_CPP),
        \ ]
  call add(cmds, "export CXXFLAGS=" . string(join(sdk_flags)))

  if repo == 'camera_engine_rkaiq'
    let cmake = printf("cmake -S. -B%s -DCMAKE_BUILD_TYPE=%s", g:BUILD_TYPE, g:BUILD_TYPE)
    let cmake .= printf(" -DIQ_PARSER_V2_EXTRA_CFLAGS='-I%s/sysroots/armv8a-aisys-linux/usr/include/rockchip-uapi;", g:SDK_DIR)
    let cmake .= printf("-I%s/sysroots/armv8a-aisys-linux/usr/include'", g:SDK_DIR)
    let cmake .= " -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DISP_HW_VERSION='-DISP_HW_V30' -DARCH='aarch64' -DRKAIQ_TARGET_SOC='rk3588'"
  else
    let cmake = printf("cmake -B %s -S . -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_BUILD_TYPE=%s -DCMAKE_INSTALL_PREFIX=/usr", g:BUILD_TYPE, g:BUILD_TYPE)
  endif

  if repo == 'libalcatraz'
    let cmake .= " -DBUILD_TESTS=0"
    if stridx(g:DEVICE, "rockx") >= 0
      let cmake .= " -DPRELOAD_OPENCV_MAT_SUPPORT=1"
    endif
  endif
  if repo == 'alcatraz-ml-library' || repo == 'badge-and-face' || repo == 'device-health' || repo == 'libalcatraz'
    if stridx(g:DEVICE, "onyx") >= 0
      let cmake .= " -DDEVICE=onyx -DPLATFORM=obsidian"
    elseif stridx(g:DEVICE, "rockx") >= 0
      let cmake .= " -DDEVICE=obsidian -DPLATFORM=obsidian"
    elseif stridx(g:DEVICE, "imx95-var-dart") >= 0
      let cmake .= " -DDEVICE=bd -DPLATFORM=bd"
    endif
  endif

  if repo == 'device-health'
    let cmake .= " -DBUILD_TESTS=ON"
  endif

  " Build specific flags
  if g:BUILD_TYPE == 'Release'
    let cmake .= ' -DCMAKE_CXX_FLAGS_RELEASE="-g1 -fno-omit-frame-pointer"'
  elseif g:BUILD_TYPE == 'RelWithDebinfo'
    let cmake .= ' -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-Og -g2"'
  elseif g:BUILD_TYPE == 'Debug'
    let cmake .= ' -DCMAKE_CXX_FLAGS_DEBUG="-O0 -g -ggdb -U_FORTIFY_SOURCE"'
  endif

  let build = printf("cmake --build %s -j 10", g:BUILD_TYPE)

  let build_dir = printf("%s/%s", FugitiveWorkTree(), g:BUILD_TYPE)
  if !isdirectory(build_dir)
    call add(cmds, cmake)
  endif
  call add(cmds, build)
  let command = ["/bin/bash", "-c", join(cmds, ';')]
  return command
endfunction

command! -nargs=0 -bang Make call qutil#Make(work#GetMakeCommand(), #{preview: <bang>0})

function! s:ChangeBuildType(new_type)
  " Avoids a lot of user errors
  call system(["ssh", g:HOST, printf("rm -r /%s/%s", g:RSYNC_DIR, g:BUILD_TYPE)])
  let g:BUILD_TYPE = a:new_type
endfunction

command! -nargs=0 Debug call s:ChangeBuildType("Debug")

command! -nargs=0 Release call s:ChangeBuildType("Release")

command! -nargs=0 RelWithDeb call s:ChangeBuildType("RelWithDeb")

function! s:ResolveEnvFile()
  let fname = expand("%:f")
  let resolved = ""
  if stridx(fname, "include/RealSenseID") >= 0
    let idx = stridx(fname, "include/RealSenseID")
    let resolved = "/home/stef/bd-sdk/" . fname[idx:]
  elseif stridx(fname, "include/alcatraz") >= 0
    let idx = stridx(fname, "include/alcatraz")
    let resolved = "/home/stef/libalcatraz/" . fname[idx:]
  elseif stridx(fname, "include/rockchip") >= 0
    let basename = fnamemodify(fname, ":t")
    let resolved = "/home/stef/mpp/inc/" . basename
  elseif stridx(fname, "include/liveMedia") >= 0
    let part = matchlist(fname, 'include/liveMedia/\(.*\)')[1]
    let resolved = "/home/stef/live/liveMedia/include/" . part
  elseif stridx(fname, "include/UsageEnvironment") >= 0
    let part = matchlist(fname, 'include/UsageEnvironment/\(.*\)')[1]
    let resolved = "/home/stef/live/UsageEnvironment/include/" . part
  elseif stridx(fname, "include/BasicUsageEnvironment") >= 0
    let part = matchlist(fname, 'include/BasicUsageEnvironment/\(.*\)')[1]
    let resolved = "/home/stef/live/BasicUsageEnvironment/include/" . part
  elseif stridx(fname, "include/groupsock") >= 0
    let part = matchlist(fname, 'include/groupsock/\(.*\)')[1]
    let resolved = "/home/stef/live/groupsock/include/" . part
  elseif stridx(fname, "hiredis") >= 0
    let basename = fnamemodify(fname, ":t")
    let resolved = "/home/stef/hiredis/" .. basename
  endif

  if filereadable(resolved)
    let view = winsaveview()
    exe "edit " . resolved
    call winrestview(view)
  else
    let Cb = function('s:OnEnvRepo', [fname])
    call qutil#CreateOneShotQuickfix(qutil#GetRepos(), 'Choose repo', Cb)
    echo "Not found in database, please choose where to search!"
  endif
endfunction

function! s:OnEnvRepo(fname, repo)
  let basename = fnamemodify(a:fname, ':t')
  let files = qsearch#GetFiles(a:repo, "-name", basename)
  let parts = split(a:fname, '/', 1)
  for pos in range(1, 3)
    let str = join(parts[-pos:-1], '/')
    let new_files = filter(copy(files), 'stridx(v:val, str) >= 0')
    if empty(new_files)
      break
    endif
    let files = new_files
  endfor
  call qutil#CreateOneShotQuickfix(files, 'Matches', function('s:DropEnvFile'))
endfunction

function! s:DropEnvFile(file)
  let view = winsaveview()
  exe "edit " . a:file
  call winrestview(view)
endfunction

command! -nargs=0 Clean call system("rm -rf " . FugitiveFind(g:BUILD_TYPE))
command! -nargs=0 -bang Remake exe "Clean" | exe "Make<bang>"
nnoremap <silent> <leader>env :call <SID>ResolveEnvFile()<CR>

function! s:ListPackages(args)
  let paths = []
  call add(paths, g:SDK_DIR .. "/sysroots/armv8a-aisys-linux/usr/lib/pkgconfig")
  call add(paths, g:SDK_DIR .. "/sysroots/armv8a-aisys-linux/usr/share/pkgconfig")
  let cmd = printf("PKG_CONFIG_PATH=%s pkg-config --list-all", join(paths, ":"))
  let output = init#SystemOrThrow(cmd)
  call filter(output, "stridx(tolower(v:val), tolower(a:args)) >= 0")
  call init#CustomBottomBuffer('Packages', output)
endfunction

command! -nargs=* Packages call s:ListPackages(<q-args>)
"}}}

""""""""""""""""""""""""""""Host commands"""""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:GetJournalCmd(service_name)
  let service_path = "/usr/lib/systemd/system/" .. a:service_name
  let output = init#SystemOrThrow(["ssh", g:HOST, 'cat ' .. service_path])
  let service_name = fnamemodify(service_path, ':t:r')
  let m = matchstrlist(output, 'Description=\(.*\)', #{submatches: v:true})
  if !exists("m[0].submatches[0]")
    echo "Failed to parse description in systemd file!"
    return
  endif
  let msg = "Started " .. m[0].submatches[0] .. "."
  let cmd = printf('journalctl MESSAGE="%s" -r -o short-unix', msg)
  let output = init#SystemOrThrow(["ssh", g:HOST, cmd])

  if stridx(output[0], "No entries") < 0
    let timestamp = split(output[0])[0]
  else
    let timestamp = 0
  endif
  let output = init#SystemOrThrow(["ssh", g:HOST, 'date --date="@' .. timestamp .. '" "+%F %T"'])
  let since = output[0]
  let cmd = printf('journalctl -u %s --since="%s"', service_name, since)
  return cmd
endfunction

function! s:Journal(bang, service_name)
  let cmd = s:GetJournalCmd(a:service_name)
  if !empty(a:bang)
    sp enew
    call init#Termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    call init#CustomBottomBuffer('Journal ' .. a:service_name, lines)
  endif
endfunction

function! s:JournalPriority(bang, args)
  let prio = ["err", "warning", "info"]
  call qutil#CreateOneShotQuickfix(prio, "Priorities", function("s:OnPriority", [a:bang, a:args]))
endfunction

function! s:OnPriority(bang, args, prio)
  let cmd = s:GetJournalCmd(a:args)
  let cmd = printf("%s -p %s", cmd, a:prio)
  if !empty(a:bang)
    sp enew
    call init#Termopen(["ssh", g:HOST, cmd .. " -f"])
  else
    let lines = systemlist(["ssh", g:HOST, cmd])
    call init#CustomBottomBuffer('Journal ' .. a:args, lines)
  endif
endfunction

function! JournalCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let services = s:GetServices()
  return filter(services, 'stridx(v:val, a:ArgLead) >= 0')
endfunction

command! -nargs=1 -bang -complete=customlist,JournalCompl Journal call s:Journal("<bang>", <q-args>)
command! -nargs=1 -bang -complete=customlist,JournalCompl JP call s:JournalPriority("<bang>", <q-args>)

cabbr J Journal

" TODO: Refactor health logic to use CreateMultiQuickfix? It's different thoough...

function! s:OnJobMaxOutput(cmds, max_output, cb, ...)
  if exists("s:job_collected_data")
    echo "Cannot start job, busy!"
    return
  endif

  call assert_true(!exists("s:job_max_data"))
  call assert_true(type(a:cb) == v:t_string)
  let s:job_collected_data = []
  let s:job_max_data = a:max_output

  let Cb = function(a:cb, a:000)
  let WrapCb = {_0, _1, _2 -> Cb(s:ForwardMaxOutput()) }
  return init#Jobstart(a:cmds, #{on_stdout: function("s:CollectMaxOutput"), on_exit: WrapCb})
endfunction

function! s:CollectMaxOutput(job, data, _1)
  if len(s:job_collected_data) < s:job_max_data
    if len(s:job_collected_data) > 0 && len(a:data) > 0 && strptime('%b %d %H:%M:%S', a:data[0]) == 0
      let s:job_collected_data[-1] ..= a:data[0]
      call extend(s:job_collected_data, a:data[1:])
    else
      call extend(s:job_collected_data, a:data)
    endif
  else
    call jobstop(a:job)
  endif
endfunction

function! s:ForwardMaxOutput()
  let ret = s:job_collected_data
  unlet s:job_collected_data
  unlet s:job_max_data
  return ret
endfunction

function s:ChooseBootLogs(bang)
  let services = s:GetServices()
  let enabled = []
  for service in services
    let e = stridx(service, "badge-and-face") < 0
    call add(enabled, e)
  endfor
  if empty(a:bang)
    call s:ShowBootLogs(enabled)
  else
    call qutil#CreateMultiQuickfix(services, enabled, 'Boot', function("s:ShowBootLogs"))
  endif
endfunction

function s:ShowBootLogs(enabled)
  let cmd = ["journalctl", "-b", "--no-pager"]
  let services = s:GetServices()
  for idx in range(len(services))
    if a:enabled[idx]
      call add(cmd, "_SYSTEMD_UNIT=" .. services[idx])
    endif
  endfor
  call add(cmd, "+")
  for prio in range(0, 4)
    call add(cmd, "PRIORITY=" .. prio)
  endfor
  call s:OnJobMaxOutput(["ssh", g:HOST, join(cmd)], 100000, "s:OnBootLogs")
endfunction

function! s:OnBootLogs(output)
  enew
  call setline(1, a:output)
  setlocal nomodified nomodifiable
  " Color warnings / errors in a separate job
  let nr = bufnr()
  let b:logs = a:output
  let b:cb_count = len(range(0, 4))
  for prio in range(0, 4)
    let cmd = ["journalctl", "-q", "-b", "--no-pager", "PRIORITY=" .. prio]
    let hl = prio < 4 ? "ErrorMsg" : "WarningMsg"
    call init#OnJobOutput(["ssh", g:HOST, join(cmd)], "work#OnBootColoredLog", nr, hl)
  endfor
endfunction

function! work#OnBootColoredLog(bufnr, hl, output)
  let ns = nvim_create_namespace('boot')
  let idx = 0
  let haystack = getbufvar(a:bufnr, "logs")
  for needle in a:output
    if !empty(needle)
      let pos = index(haystack, needle, idx)
      if pos >= 0
        call nvim_buf_set_extmark(a:bufnr, ns, pos, 0, #{line_hl_group: a:hl})
        let idx = pos + 1
      else
        call setbufvar(a:bufnr, "show_warning", v:true)
      endif
    endif
  endfor

  let count = getbufvar(a:bufnr, "cb_count") - 1
  call setbufvar(a:bufnr, "cb_count", count)
  if count == 0
    if getbufvar(a:bufnr, "show_warning")
      call init#Warn("Partial highlight.")
    endif
    call setbufvar(a:bufnr, "logs", [])
    let uptime = init#SystemOrThrow(["ssh", g:HOST, "uptime -p"])
    echo uptime[0]
  endif
endfunction

command! -nargs=0 -bang Boot call s:ChooseBootLogs("<bang>")
command! -nargs=0 -bang Uptime call s:ChooseBootLogs("<bang>")

function! s:RemoteHistoryFile()
  let dir = stdpath('state') .. "/history"
  if !isdirectory(dir)
    call mkdir(dir, "p")
  endif
  return printf("%s/%s.bash_history", dir, g:DEVICE)
endfunction

function! s:SyncRemoteHistory()
  let file = s:RemoteHistoryFile()
  let remote_history = init#SystemOrThrow(["ssh", g:HOST, "cat ~/.bash_history 2>/dev/null || true"])
  let local_history = filereadable(file) ? readfile(file) : []

  let seen = {}
  let merged = []
  for line in reverse(local_history + remote_history)
    if !empty(line) && !has_key(seen, line)
      let seen[line] = 1
      call add(merged, line)
    endif
  endfor
  call writefile(reverse(merged), file)
endfunction

function! s:OpenTerminal(arg)
  if empty(a:arg)
    call init#SshTerminal()
    return
  endif

  call s:SyncRemoteHistory()
  let cmds = readfile(s:RemoteHistoryFile())

  call reverse(cmds)
  call filter(cmds, "stridx(v:val, a:arg) >= 0")
  let label = 'Remote command'
  call qutil#CreateCustomQuickfix(cmds, label, function("s:ExecuteCommand"))
endfunction

function! s:ExecuteCommand()
  let lnum = line('.')
  let buf = bufnr()
  let job_result = getbufvar(buf, 'job_result', #{})
  if has_key(job_result, lnum)
    let [code, lines] = job_result[lnum]
    if empty(lines) || (len(lines) == 1 && empty(lines[0]))
      echo "Nothing to show."
      return
    endif
    let description = (code == 0) ? 'Output' : 'Error'
    return init#CustomBottomBuffer(description, lines)
  endif
  let cmd = ["ssh", g:HOST, getline(lnum)]
  call init#OnJobResult(cmd, #{stdout: 1, stderr: 1, exit_code: 1}, function('s:OnExecutedCommand', [buf, lnum]))
  let ns = nvim_create_namespace('command_result')
  call nvim_buf_set_extmark(buf, ns, lnum - 1, 0, #{line_hl_group: 'DiagnosticUnnecessary'})
endfunction

function! s:OnExecutedCommand(buf, lnum, result)
  let job_result = getbufvar(a:buf, 'job_result', #{})
  let exit_code = a:result.exit_code
  let ns = nvim_create_namespace('command_result')
  if exit_code == 0
    let job_result[a:lnum] = [exit_code, a:result.stdout]
    call nvim_buf_set_extmark(a:buf, ns, a:lnum - 1, 0, #{line_hl_group: 'DiagnosticOk'})
  else
    let job_result[a:lnum] = [exit_code, a:result.stderr]
    call nvim_buf_set_extmark(a:buf, ns, a:lnum - 1, 0, #{line_hl_group: 'DiagnosticError'})
  endif
  call setbufvar(a:buf, 'job_result', job_result)
endfunction

command! -nargs=* T call s:OpenTerminal(<q-args>)

function! s:RemoteFileCommand(what, cb)
  if empty(a:what)
    let files = init#RemoteRecentFiles(g:HOST)
  else
    call system(["ssh", g:HOST, "[ -f " .. a:what .. " ]"])
    if v:shell_error
      let files = init#RemoteFindFiles(g:HOST, a:what)
    else
      let files = [a:what]
    endif
  endif
  if len(files) <= 0
    echo "Nothing to show."
  else
    call qutil#CreateOneShotQuickfix(files, 'Remote files', a:cb)
  endif
endfunction

function! work#SelectRemoteFile(file)
  call init#Sshfs(g:HOST, a:file)
endfunction

function! work#DownloadRemoteFile(file)
  let url = printf("%s:%s", g:HOST, a:file)
  call init#SystemOrThrow(["rsync", url, expand("~/Downloads")])
  let result = expand("~/Downloads/" .. fnamemodify(a:file, ":t"))
  if filereadable(result)
    call init#ToClipboard(result)
    let bytes = readfile(result, 'b', 200)
    for l in bytes
      if l =~# '[^\x09\x0A\x0D\x20-\x7E]'
        echo "Download " .. result
        return
      endif
    endfor
    exe "e " .. result
  endif
endfunction

function! work#Upload(path)
  if !filereadable(expand("%:p"))
    return init#Warn("No file to upload!")
  endif
  let dest = empty(a:path) ? printf("%s/%s", g:RSYNC_DIR, expand("%:t")) : a:path
  call init#Upload(g:HOST, dest)
endfunction

function! SshfsCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return init#RemoteFindFiles(g:HOST, a:ArgLead)
endfunction

function! UploadCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return init#RemoteFindDirs(g:HOST, a:ArgLead)
endfunction

function! RemoteExeCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let pat = "*" . a:ArgLead . "*"
  let find = printf("find %s/%s -name %s -type f -executable", g:RSYNC_DIR, g:BUILD_TYPE, shellescape(pat))
  let result = systemlist(["ssh", "-o", "ConnectTimeout=1", g:HOST, find])
  return filter(result, 'v:val !~ ".sh$"')
endfunction

function! s:OnRsyncStdout(_0, data, _1)
  for data in a:data
    let text = substitute(data, '\n', '', 'g')
    if len(text) > 0
      let m = matchlist(text, '[0-9]\+%')
      if len(m) > 0 && !empty(m[0])
        let g:statusline_dict['sync'] = m[0]
      endif
    endif
  endfor
endfunction

function! s:OnRsyncExit(post_cmds, cb, _0, code, _1)
  if a:code == 0
    if !empty(a:post_cmds)
      call init#Jobstart(["ssh" , g:HOST, a:post_cmds])
    endif
    call function(a:cb)()
  else
    echom "Sync failed!"
  endif
  let g:statusline_dict['sync'] = ''
endfunction

function! s:RemoteSyncExes(dir, exes, cb)
  let dir = a:dir
  if !isdirectory(dir) && !filereadable(dir)
    echo "Not found: " . dir
    return
  endif
  " Remove leading / or rsync will be naughty
  if dir[-1:-1] == '/'
    let dir = dir[0:-2]
  endif
  const remote_dir = g:HOST . ":" . g:RSYNC_DIR

  let cmd = ["rsync", "-rlt"]
  " Include all directories
  call add(cmd, '--include=*/')
  " Include all executables
  let post_cmds = []
  for exe in a:exes
    call add(cmd, '--include=' . exe)
    " Post cmd
    let remote_exe = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, exe)
    if exe =~ 'obsidian-video$' || exe =~ 'rock-video$'
      call add(post_cmds, "setcap cap_sys_nice+ep " .. remote_exe)
    elseif exe =~ 'mock_video$'
      call add(post_cmds, "setcap cap_kill+ep " .. remote_exe)
    elseif exe =~ 'librsid_debug.so$'
      call add(post_cmds, "cp " .. remote_exe .. " /usr/lib")
    endif
  endfor
  " Exclude rest. XXX: ORDER OF FLAGS MATTERS!
  call add(cmd, '--exclude=*')
  call extend(cmd, ["--info=progress2", "--out-format='%n'", dir, remote_dir])

  let OnExit = funcref("s:OnRsyncExit", [join(post_cmds, ';'), a:cb])
  call init#Jobstart(cmd, #{on_stdout: funcref("s:OnRsyncStdout"), on_exit: OnExit})
endfunction

function! s:GetSyncTargets(...)
  let pat = get(a:000, 0, '.*')
  let dir = FugitiveFind(g:BUILD_TYPE)
  let exes = systemlist(["find", dir, "-type", "f", "-executable", "-regex", pat, "-printf", "%P\n"])
  return exes
endfunction

function! s:RemoteSyncAll(dir)
  function! s:ShowSyncMessage()
    echo "Synced!"
  endfunction
  let exes = s:GetSyncTargets()
  call s:RemoteSyncExes(a:dir, exes, "s:ShowSyncMessage")
endfunction

function work#SyncOne(bang, dir, exe)
  if exists('s:services_status')
    let systemd_name = s:GetServiceName(a:exe)
    let status = get(s:services_status, systemd_name, "inactive")
    if a:bang != "!" && status != "inactive" && status != "failed"
      return init#Warn("Service %s is %s!", systemd_name, status)
    endif
  endif
  " Build clipboard string.
  let remote_exe = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:exe)
  " Check if there is a configured user.
  let [user, flags] = s:GetUserAndFlags(remote_exe)
  let cmd = remote_exe
  if !empty(user)
    let cmd = printf("sudo -u %s %s", user, cmd)
  endif
  if !empty(flags)
    let cmd = printf("%s %s", cmd, flags)
  endif
  call s:RemoteSyncExes(a:dir, [a:exe], function("init#ToClipboard", [cmd]))
endfunction

command! -bang -nargs=? -complete=customlist,SyncCompl Sync
      \ call s:GetSyncTargets()->qutil#CommandPass(<q-args>)->qutil#CreateOneShotQuickfix('Sync', 'work#SyncOne', "<bang>", FugitiveFind(g:BUILD_TYPE))

function! SyncCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return s:GetSyncTargets()->qutil#FileCompletionPass(a:ArgLead)
endfunction

function! s:Resync()
  let dir = FugitiveFind(g:BUILD_TYPE)
  call qutil#Make(work#GetMakeCommand(), #{on_success: { -> s:RemoteSyncAll(dir)}})
endfunction

function! work#Debug(arg, opts)
  let opts = a:opts
  const exe = split(a:arg, ' ')[0]
  let opts['exe'] = a:arg
  let opts['ssh'] = g:HOST

  " Check if there is a configured user/flags.
  let [user, flags] = s:GetUserAndFlags(exe)
  if !empty(user)
    let opts['user'] = user
  endif
  " Don't override flags set by a:arg
  if a:arg == exe && !empty(flags)
    let opts['exe'] = printf('%s %s', exe, flags)
  endif

  " Add a command to be executed once there is an inferior.
  if !has_key(opts, 'post_cmds')
    let opts['post_cmds'] = []
  endif
  let aisys_sdk_subst = printf('set substitute-path /usr/src/debug %s/sysroots/armv8a-aisys-linux/usr/src/debug', g:SDK_DIR)
  call add(opts['post_cmds'], aisys_sdk_subst)

  " Call main debugging routine.
  call init#Debug(opts)
endfunction

function! s:GetApps()
  let apps = #{
        \ rtsp-server: #{user: "rtsp-server", service: "rtsp-server.service"},
        \ badge_and_face: #{user: "badge_and_face", service: "badge-and-face.service"},
        \ qrcode-scanner: #{user: "rock-bootstrap", service:"qrcode-scanner.service"},
        \ device-health: #{user: "device-health", service: "device-health.service"},
        \ }
  if stridx(g:DEVICE, "imx95-var-dart") >= 0
    let apps["bd-video"] = #{user: "rock-video", service: "bd-video.service"}
  elseif stridx(g:DEVICE, "rockx") >= 0
    let apps["obsidian-video"] = #{user: "rock-video", service: "obsidian-video.service"}
  elseif stridx(g:DEVICE, "onyx") >= 0
    let apps["rock-video"] = #{user: "rock-video", service: "rock-video.service"}
  endif
  return apps
endfunction

function! s:GetUserAndFlags(exe)
  let key = fnamemodify(a:exe, ':t')
  let apps = s:GetApps()
  if has_key(apps, key)
    let user = get(apps[key], 'user', '')
    return [user, '']
  endif
  if key == 'mock_video'
    return ['rock-video', '/tmp/capture']
  elseif key == 'capture-video'
    return ['rock-video', '-n=100']
  endif
  return ['', '']
endfunction

function! s:GetServiceName(exe)
  let key = fnamemodify(a:exe, ':t')
  return init#Get(s:GetApps(), key, 'service', '')
endfunction

function! s:RunAsService(exe)
  let remote_path = printf("%s/%s/%s", g:RSYNC_DIR, g:BUILD_TYPE, a:exe)
  let exe_name = fnamemodify(remote_path, ":t")
  let systemd_name = s:GetServiceName(a:exe)
  if empty(systemd_name)
    return "Unsupported: " .. exe_name
  endif
  let cmds = []
  call add(cmds, printf("echo Stopping %s...", systemd_name))
  call add(cmds, "systemctl stop " .. systemd_name)
  call add(cmds, printf("rsync -a --xattrs %s /usr/bin/", remote_path))
  call add(cmds, printf("echo Starting %s...", systemd_name))
  call add(cmds, "systemctl start " .. systemd_name)

  sp
  enew
  let id = init#Termopen(["ssh", g:HOST, join(cmds, ' && ')])
  call init#OnTermSuccess(id, function('s:Journal', ['!', systemd_name]))
endfunction

function! s:DetermineConfig(host, Cb)
  call init#OnJobOutput(["ssh", '-G', a:host], expand("<SID>") .. 'OnConfig', a:host, a:Cb)
endfunction

function! s:OnConfig(host, Cb, output)
  let control = filter(copy(a:output), 'v:val =~ "^controlpath"')
  if empty(control)
    call init#Warn("Control file does not exist for " .. a:host)
    let g:HOST_CONTROL = ""
  else
    let g:HOST_CONTROL = expand(split(control[0])[1])
  endif

  let ip = filter(copy(a:output), 'v:val =~ "^hostname"')
  if empty(ip)
    call init#Warn("Failed to determine IP for " .. a:host)
    let g:HOST_IP = ""
  else
    let g:HOST_IP = expand(split(ip[0])[1])
  endif

  let g:HOST = a:host
  call a:Cb()
endfunction

function! work#ControlFileExists()
  return has_key(g:, "HOST_CONTROL") && !empty(g:HOST_CONTROL) && filereadable(g:HOST_CONTROL)
endfunction

function! work#GetHostStatus()
  return get(s:, 'control_file_exists', v:false)
endfunction

function! work#IsHostSimulated()
  const is_invalid = stridx(g:HOST, ".invalid") >= 0
  return is_invalid
endfunction

function! s:MonitorControlFile()
  call init#Jobstart("inotifywait -mq -e create,delete ~/.ssh", #{on_stdout: expand("<SID>") .. 'OnControlFileEvent'})
  call s:OnControlFileEvent()
endfunction

function! s:OnControlFileEvent(...)
  let s:control_file_exists = work#ControlFileExists()
  if !s:control_file_exists
    echom "SSH master died..."
  endif
  redrawstatus
endfunction

function! s:EnsureMaster()
  if work#ControlFileExists()
    call init#OnJobExit(["ssh", "-O", "check", "-S", g:HOST_CONTROL, g:HOST], function("s:OnMasterCheck"))
  else
    call s:StartMaster()
  endif
endfunction

function! s:OnMasterCheck(code)
  if a:code == 0
    call s:OnMasterRunning(a:code)
  else
    call delete(g:HOST_CONTROL)
    call init#OnJobExit(["ssh", "-O", "exit", "-o", "ControlPath=" .. g:HOST_CONTROL, g:HOST], function("s:StartMaster"))
  endif
endfunction

function! s:StartMaster(...)
  let cmd = ["ssh", "-o", "ConnectTimeout=1", "-o", "ControlPath=" .. g:HOST_CONTROL,
        \ "-o", "ControlPersist=yes", "-o", "StrictHostKeyChecking=accept-new", "-M", "-N",
        \ g:HOST]
  call init#OnJobExit(cmd, function("s:OnMasterRunning"))
endfunction

function! s:OnMasterRunning(code)
  if a:code != 0
    call init#Warn("Failed to start SSH master!")
    return
  endif

  call s:MonitorControlFile()
  let cmd = "systemctl is-active " .. join(s:GetServices(), " ")
  call init#OnJobOutput(["ssh", g:HOST, cmd], function('s:StartServiceMonitor'))
endfunction

function! s:AddBackdoor()
  let cmds = []

  " Enable authorized_keys again
  call add(cmds,
        \ "sed -i 's|^AuthorizedKeysFile[[:space:]].*|AuthorizedKeysFile /root/.ssh/authorized_keys|' /etc/ssh/sshd_config")

  " Create root ssh dir with proper perms
  call add(cmds, "mkdir -p /root/.ssh")
  call add(cmds, "chmod 700 /root/.ssh")

  " Copy the currently working user's authorized keys
  call add(cmds, "cat > /root/.ssh/authorized_keys")
  call add(cmds, "chown root:root /root/.ssh/authorized_keys")
  call add(cmds, "chmod 600 /root/.ssh/authorized_keys")

  " Validate + restart ssh
  call add(cmds, "sshd -t")
  call add(cmds, "systemctl restart sshd.socket")

  let once_guard = 'test -f /root/.ssh/authorized_keys'
  let backdoor_cmd = printf('sudo sh -c "%s || (%s)"', once_guard, join(cmds, " && "))

  const host = "alcatraz@" .. g:HOST
  let id = init#OnJobSuccess(["ssh", host, backdoor_cmd], function("s:OnFixedHost"))
  let auth_file = readfile(expand("~/.ssh/id_ed25519.pub"))
  call chansend(id, auth_file)
  call chanclose(id, 'stdin')
endfunction

command! -nargs=0 Backdoor call s:AddBackdoor()

function! s:OnFixedHost()
  call init#OnJobOutput(["ssh", g:HOST, "mount"], function('s:OnDeviceMounts'))
  call s:DetermineRsyncDir()
  call s:DetermineSdk()
  call s:CheckMenderCommit()
  let cmd = "systemctl is-active " .. join(s:GetServices(), " ")
  call s:EnsureMaster()
endfunction

function! s:OnDeviceMounts(mnt)
  let mnt = filter(a:mnt, 'stridx(v:val, "on /usr ") >= 0')
  if empty(mnt)
    return
  endif
  let flags = split(matchstr(mnt[0], '([a-zA-Z,]*)')[1:-2], ",")
  if index(flags, "ro") >= 0
    call init#Jobstart(["ssh", g:HOST, "mount -o remount,rw /usr"])
  endif
endfunction

function s:DetermineSdk()
  let cmd = ["ssh", g:HOST, "cat /var/lib/mender/device_type || ls /usr/lib/librsid.so"]
  call init#OnJobOutput(cmd, expand("<SID>") .. 'OnSdkOutput')
endfunction

function! s:OnSdkOutput(output)
  let g:DOCKER_COMPOSE = "docker-compose.yaml"
  let g:DOCKER_CACHE = expand("~/aicache")
  let g:AIDISTRO = expand("~/aidistro")
  if stridx(a:output[0], "librsid.so") >= 0
    let g:DEVICE = "imx95-var-dart"
    let g:SDK_DIR = "/opt/aisys/imx95_var_dart"
    let g:DOCKER_COMPOSE = "docker-compose.bd.yaml"
    let g:DOCKER_CACHE = printf("/home/%s/aicache-bd", $USER)
    let g:AIDISTRO = expand("~/aidistro-bd")
  elseif stridx(a:output[0], "rockx-dm-p15") >= 0
    let g:DEVICE = "rockx-dm-p15"
    let g:SDK_DIR = "/opt/aisys/obsidian_p15"
  elseif stridx(a:output[0], "rockx-dm-r10") >= 0
    let g:DEVICE = "rockx-dm-r10"
    let g:SDK_DIR = "/opt/aisys/obsidian_r10"
  elseif stridx(a:output[0], "onyx-p1") >= 0
    let g:DEVICE = "onyx-p1"
    let g:SDK_DIR = "/opt/aisys/onyx_p1"
  elseif stridx(a:output[0], "onyx-cr") >= 0
    let g:DEVICE = "onyx-cr"
    let g:SDK_DIR = "/opt/aisys/onyx_cr"
  endif
  let g:objdump_exe = g:SDK_DIR .. "/sysroots/x86_64-aisdk-linux/usr/bin/aarch64-aisys-linux/aarch64-aisys-linux-objdump"
  let libstd_cpp_dir = g:SDK_DIR .. "/sysroots/armv8a-aisys-linux/usr/include/c++"
  call init#OnJobOutput(["ls", "-1", libstd_cpp_dir], function("s:OnLibstdVersions"))
endfunction

function! s:CompareVersions(a, b)
  let [a_maj, a_min; _] = split(a:a, '\.')
  let [b_maj, b_min; _] = split(a:b, '\.')
  if a_maj != b_maj
    return a_maj - b_maj
  else
    return a_min - b_min
  endif
endfunction

function! s:OnLibstdVersions(output)
  let versions = sort(filter(a:output, "!empty(v:val)"), function("s:CompareVersions"))
  if empty(versions)
    call init#Warn("Missing SDK: " .. g:DEVICE)
  else
    let g:LIBSTD_CPP = versions[-1]
  endif
endfunction

" TODO: Kind of hacky and might need updating, but I think it's going to be worth it!
function! s:SimulateHost(simulated_sdk)
  if !work#IsHostSimulated()
    let g:HOST .= ".invalid"
    let g:HOST_IP = g:HOST
    let g:HOST_CONTROL .= ".invalid"
    let g:RSYNC_DIR = "/dev/null"
    call s:OnControlFileEvent()
  endif
  call s:OnSdkOutput([a:simulated_sdk])
endfunction

command! -nargs=1 -complete=customlist,SimulateCompl Simulate call s:SimulateHost(<q-args>)
cabbr Sim Simulate

function! SimulateCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let options = ["librsid.so", "rockx-dm-p15", "rockx-dm-r10", "onyx-p1", "onyx-cr"]
  return filter(options, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! s:InstallHostCommands()
  command! -nargs=? -complete=customlist,RemoteExeCompl Start call init#TryCall('work#Debug', <q-args>, #{})
  command! -nargs=? -complete=customlist,RemoteExeCompl Run call init#TryCall('work#Debug', <q-args>, #{br: init#GetDebugLoc()})
  command! -nargs=? -complete=customlist,RemoteExeCompl File call init#TryCall('work#Debug', <q-args>, #{wait: 1})

  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Attach call init#RemoteAttach('%s', <q-args>)", g:HOST)
  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Ratch call init#RemoteAttach('%s', <q-args>, v:true)", g:HOST)
  exe printf("command! -nargs=0 Ssh call init#SshTerm('%s')", g:HOST)

  command! -nargs=? -complete=customlist,UploadCompl Upload call work#Upload(<q-args>)
  command! -nargs=? -complete=customlist,SshfsCompl Ssfs call s:RemoteFileCommand(<q-args>, 'work#SelectRemoteFile')
  command! -nargs=? -complete=customlist,SshfsCompl Download call s:RemoteFileCommand(<q-args>, 'work#DownloadRemoteFile')
  cabbr SSfs Ssfs

  nnoremap <silent> <leader>rb <cmd>Sync badge_and_face<CR>
  nnoremap <silent> <leader>sb <cmd>call <SID>RunAsService("bin/badge_and_face")<CR>
  nnoremap <silent> <leader>rs <cmd>Sync rtsp-server<CR>
  if stridx(g:DEVICE, "onyx") >= 0
    nnoremap <silent> <leader>rv <cmd>Sync rock-video<CR>
    nnoremap <silent> <leader>sv <cmd>call <SID>RunAsService("pipeline/rock-video")<CR>
  elseif stridx(g:DEVICE, "rockx") >= 0
    nnoremap <silent> <leader>rv <cmd>Sync obsidian-video<CR>
    nnoremap <silent> <leader>rf <cmd>Sync focus-tool<CR>
    nnoremap <silent> <leader>rq <cmd>Sync qrcode-scanner<CR>
    nnoremap <silent> <leader>sv <cmd>call <SID>RunAsService("application/obsidian-video")<CR>
    nnoremap <silent> <leader>ss <cmd>call <SID>RunAsService("application/rtsp-server")<CR>
  endif
  nnoremap <silent> <leader>re <cmd>call <SID>Resync()<CR>
  nnoremap <silent> <leader>sdk <cmd>call <SID>FakeSdk()<CR>
endfunction

function s:OnHostChange()
  if !work#IsHostSimulated()
    call s:InstallHostCommands()
    " Patch in order to avoid 'Connection reset by peer' errors.
    let fix_ssh_cmd = 'test -d /run/sshd || (mkdir -p /run/sshd && chmod 0755 /run/sshd)'
    let opts = #{stderr: 1, exit_code: 1}
    call init#OnJobResult(["ssh", "-o", "ConnectTimeout=1", g:HOST, fix_ssh_cmd], opts, function("s:OnAttemptSSH"))
  endif
endfunction

function s:OnAttemptSSH(res)
  let code = a:res.exit_code
  if code == 0
    call s:OnFixedHost()
  elseif join(a:res.stderr) =~? 'permission denied'
    echo "SSH job failed due to permissions! Possible fix :Backdoor"
  elseif join(a:res.stderr) =~? 'timed out'
    echo "SSH job timed out! Wait for connection via :Host"
  elseif join(a:res.stderr) =~? 'key verification failed'
    echo "SSH key has changed! Trust again via :Host"
  else
    echo "SSH job failed!"
    call init#ShowErrors(a:res.stderr)
  endif
endfunction

function! HostCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let lines = readfile("/home/" .. $USER .. "/.ssh/config")
  let matches = matchstrlist(lines, 'Host \(\i\+\)$', #{submatches: v:true})
  let hosts = map(matches, "v:val.submatches[0]")
  return filter(hosts, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! s:ChangeHost(host)
  if empty(a:host)
    echo "Current host is: " .. g:HOST
  else
    call s:DetermineConfig(a:host, function('s:OnHostResolvedIP'))
  endif
endfunction

function! s:OnHostResolvedIP()
  let cmds = []
  call add(cmds, "ssh-keygen -R " .. g:HOST_IP)
  call add(cmds, "echo 'Waiting for connection...'")
  call add(cmds, "ssh_wait " .. g:HOST)

  botr split
  enew
  let id = init#Termopen(join(cmds, ";"))
  call init#TermHide(id)
  call init#OnTermSuccess(id, expand("<SID>") .. "OnHostChange")
endfunction

command! -nargs=? -complete=customlist,HostCompl Host call s:ChangeHost(<q-args>)
"}}}

""""""""""""""""""""""""""""Do"""""""""""""""""""""""""""" {{{
function! DoCompl(ArgLead, CmdLine, CursorPos)
  let nargs = len(split(a:CmdLine))
  if a:CursorPos < len(a:CmdLine) || nargs > 2
    return []
  endif
  let cmds = ["StopServices", "DropClients", "UpdateDocker", "RunDocker", "Bb",
        \ "BuildImage", "ShowSdk", "BuildSdk", "InstallSdk", "ShowImage", "SaveImage",
        \ "InstallImage", "RefreshImage", "RefreshSdk", "RefreshBoth",
        \ "FactoryReset", "Enroll", "HostDebugSyms", "PlotTrace", "BarfPlotTrace",
        \ "OpenCV", "MemoryMonitor", "EnableCore", "CheckHealth"]
  return filter(cmds, 'v:val =~? a:ArgLead')
endfunction

function s:GetServices()
  let services = map(values(s:GetApps()), 'v:val.service')
  call add(services, "rtsp-server-noauth.service")
  call add(services, "rtsp-server.socket")
  return services
endfunction

function! s:StopServices()
  call s:OpenServices()

  let stop_list = s:GetServices()
  let cmd = "systemctl stop"
  for service in stop_list
    let cmd ..= " " . service
  endfor

  call init#Jobstart(["ssh", g:HOST, cmd])
endfunction

function! s:DropClients()
  sp ~/obsidian-video
  Source fd_transmitter
  if search("DropClient.*Force dropped") == 0
    echo "Failed to find drop call site"
    return
  endif
endfunction

function! s:UpdateDocker()
  sp
  enew
  lcd ~/aidocker
  let cmd = printf("sudo docker-compose -f %s build ubuntu22", g:DOCKER_COMPOSE)
  call init#Termopen(cmd)
  startinsert
endfunction

function! s:RunDocker(...)
  sp
  enew
  lcd ~/aidocker
  let cmds = ["sudo", "docker-compose", "-f", g:DOCKER_COMPOSE, "run", "--rm", "ubuntu22"]

  let machine = g:DEVICE
  if filereadable(printf("%s/layers/meta-ai/conf/machine/%s-dev.conf", g:AIDISTRO, g:DEVICE))
    let machine = g:DEVICE .. '-dev'
  endif

  let bash_cmd = ["export USE_S3_BUCKET=1",
        \ printf("export MACHINE=%s", machine),
        \ printf("source %s/setup-environment %s", g:AIDISTRO, g:DOCKER_CACHE)]
  if a:0 > 0
    call add(bash_cmd, join(a:000))
  else
    call add(bash_cmd, "/usr/bin/bash")
  endif

  let docker_cmd = printf("/usr/bin/bash -c '%s'", join(bash_cmd, ';'))
  call add(cmds, docker_cmd)
  let id = init#Termopen(join(cmds))
  startinsert
  return id
endfunction

function s:BitbakeCommand(...)
  let opts = get(a:000, 0, #{})
  if g:DEVICE == "imx95-var-dart"
    let img_cmd = "bitbake ai-base-image"
  else
    let img_cmd = "bitbake rock-image"
  endif
  let sdk_cmd = img_cmd .. " -c populate_sdk"

  let multi = has_key(opts, "multi") && opts["multi"]
  let sdk_only = has_key(opts, "sdk") && opts["sdk"]
  if multi
    return printf("%s && %s", img_cmd, sdk_cmd)
  elseif sdk_only
    return sdk_cmd
  else
    return img_cmd
  endif
endfunction

function! s:BuildSdk()
  return s:RunDocker(s:BitbakeCommand(#{sdk: v:true}))
endfunction

function! s:BuildImage()
  " Last chance to save .bash_history before the reflash wipes it.
  call s:SyncRemoteHistory()
  return s:RunDocker(s:BitbakeCommand())
endfunction

function! s:FindSdk()
  let sdks = init#SystemOrThrow(["find", g:DOCKER_CACHE .. "/tmp/deploy/sdk/", "-regex", printf(".*%s.*.sh", g:DEVICE)])
  if empty(sdks)
    throw "No sdk found"
  endif
  let most_recent_file = sdks[0]
  let most_recent_timestamp = getftime(sdks[0])
  for file in sdks[1:]
    let curr_timestamp = getftime(file)
    if curr_timestamp > most_recent_timestamp
      let most_recent_file = file
      let most_recent_timestamp = curr_timestamp
    endif
  endfor
  return most_recent_file
endfunction

function! s:InstallSdk()
  let most_recent_file = s:FindSdk()
  let most_recent_timestamp = getftime(most_recent_file)
  let ago = init#PrettyTime(localtime() - most_recent_timestamp)

  split
  enew
  let cmds = []
  call add(cmds, printf("echo 'Found sdk from %s ago'", ago))
  call add(cmds, "rm -rf " .. g:SDK_DIR .. "/*")
  call add(cmds, printf("%s -d %s -y", most_recent_file, g:SDK_DIR))
  call init#Termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:FindImage(...)
  let ext = (g:DEVICE == "imx95-var-dart" ? "wic.zst" : "mender") 
  let regex = printf(".*%s.*%s", g:DEVICE, ext)
  let dir = get(a:000, 0, "")
  if empty(dir)
    let dir = g:DOCKER_CACHE .. "/tmp/deploy/images/"
  endif
  let images = systemlist(["find", dir, "-regex", regex])
  if empty(images)
    throw "No image found"
  endif
  let most_recent_image = images[0]
  let most_recent_timestamp = getftime(most_recent_image)
  for image in images[1:]
    let curr_timestamp = getftime(image)
    if curr_timestamp > most_recent_timestamp
      let most_recent_image = image
      let most_recent_timestamp = curr_timestamp
    endif
  endfor
  return most_recent_image
endfunction

function! s:ShowImage()
  call init#ToClipboard(s:FindImage())
endfunction

function! s:SaveImage(name)
  if empty(a:name)
    echo "Expecting name!"
    return
  endif
  let img = s:FindImage()
  let dest = printf("/home/%s/Downloads/%s.mender", $USER, a:name)
  call init#SystemOrThrow(printf("cp %s %s", img, dest))
  echo "Copied to " .. dest .. "."
endfunction

function! s:InstallImage(...)
  if a:0 > 0
    let most_recent_image = a:1
  else
    let most_recent_image = s:FindImage()
  endif

  let most_recent_timestamp = getftime(most_recent_image)
  let ago = init#PrettyTime(localtime() - most_recent_timestamp)
  let cmds = []
  call add(cmds, printf("echo 'Found image from %s ago'", ago))
  if g:DEVICE == "imx95-var-dart"
    let dev = s:FindSdCard()
    if empty(dev)
      return init#Warn("Please mount the flash drive!")
    endif

    let mounts = init#SystemOrThrow("findmnt -n -o SOURCE")
    call filter(mounts, "stridx(v:val, dev) >= 0")
    if !empty(mounts)
      call add(cmds, "umount " .. join(mounts))
    endif

    call add(cmds, printf("sudo bmaptool copy %s %s", most_recent_image, dev))
    call add(cmds, "sync")
    call add(cmds, "udisksctl power-off -b /dev/sdc")
    call add(cmds, "echo 'Please insert SD card back into device...'")
  else
    call add(cmds, printf("scp %s %s:%s/image.mender", most_recent_image, g:HOST, g:RSYNC_DIR))
    call add(cmds, printf("ssh %s 'mender install /%s/image.mender && reboot'", g:HOST, g:RSYNC_DIR))
    call add(cmds, "echo 'Waiting for device to reboot...'")
    call add(cmds, "ssh_wait_silent " .. g:HOST)
  endif
  split
  enew
  call init#Termopen(join(cmds, " && "))
  startinsert
endfunction

function! s:FindSdCard()
  const by_id = "/dev/disk/by-id/usb-Generic_MassStorageClass_000000002962-0:1"
  if !empty(getftype(by_id))
    return resolve(by_id)
  else
    return ""
  endif
endfunction

function! s:RefreshImage()
  if g:DEVICE == "imx95-var-dart" && empty(s:FindSdCard())
    return init#Warn("Please mount the flash drive!")
  endif
  let id = s:BuildImage()
  call init#OnTermSuccess(id, function("s:InstallImage"))
endfunction

function! s:ShowSdk()
  call init#ToClipboard(s:FindSdk())
endfunction

function! s:RefreshSdk()
  let id = s:BuildSdk()
  call init#OnTermSuccess(id, function("s:InstallSdk"))
endfunction

function! s:RefreshBoth()
  let id = s:RunDocker(s:BitbakeCommand(#{multi: v:true}))
  call init#OnTermSuccess(id, function("s:InstallBoth"))
endfunction

function! s:InstallBoth()
  call s:InstallImage()
  call s:InstallSdk()
endfunction

function! s:FakeSdk()
  let cmds = []
  let repo_dir = FugitiveWorkTree()
  if stridx(repo_dir, "libalcatraz") >= 0
    let so_name = "libalcatraz.so"
    let so_dir = printf("%s/%s/alcatraz", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/%s/libalcatraz.pc", repo_dir, g:BUILD_TYPE)
    call add(cmds, printf("rsync -rtv %s/include/alcatraz/ %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz", repo_dir, g:SDK_DIR))

    let health_api = printf("%s/include/alcatraz/health/device_health_api.h", repo_dir)
    let sdk_header_dir = printf("%s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/health", g:SDK_DIR)
    call add(cmds, printf("rsync -rtv %s %s", health_api, sdk_header_dir))
  elseif stridx(repo_dir, "alcatraz-ml-library") >= 0
    let so_name = "libalcatraz_ml.so"
    let so_dir = printf("%s/%s/src", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/%s/libalcatraz_ml.pc", repo_dir, g:BUILD_TYPE)
    call add(cmds, printf("rsync -rtv %s/include/ %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/ml", repo_dir, g:SDK_DIR))
    call add(cmds, printf("rsync -tv %s/include/rockchip/alcatraz_ml_sdk.h %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/ml", repo_dir, g:SDK_DIR))
  elseif stridx(repo_dir, 'mpp') >= 0
    let so_name = "librockchip_mpp.so"
    let so_dir = printf("%s/%s/mpp", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/rockchip_mpp.pc", so_dir)
  elseif stridx(repo_dir, 'hiredis') >= 0
    let so_name = "libhiredis.so"
    let so_dir = printf("%s/%s", repo_dir, g:BUILD_TYPE)
    let pc = printf("%s/hiredis.pc", so_dir)
  else
    echo "No repo matched!"
    return
  endif

  " Remove old versions of the library
  call add(cmds, printf("rm %s/sysroots/armv8a-aisys-linux/usr/lib/%s*", g:SDK_DIR, so_name))
  call add(cmds, printf("rsync -Ltv %s/%s* %s/sysroots/armv8a-aisys-linux/usr/lib", so_dir, so_name, g:SDK_DIR))
  call add(cmds, printf("rsync -Ltv %s %s/sysroots/armv8a-aisys-linux/usr/share/pkgconfig", pc, g:SDK_DIR))
  call add(cmds, printf("rsync -Ltv %s/%s* %s:/usr/lib", so_dir, so_name, g:HOST))

  split
  enew
  call init#Termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:HostDebugSyms(...)
  let dir = g:SDK_DIR .. "/sysroots/armv8a-aisys-linux/usr/lib/.debug"
  let show_only = (a:0 == 0)
  if show_only
    let pat = ".*"
  else
    let pat = ".*" .. a:1 .. ".*"
  endif
  let files = systemlist(["find", dir, "-regex", pat])
  if !show_only
    let bytes = 0
    for file in files
      let bytes += getfsize(file)
    endfor
    let max_bytes = 300 * 1000 * 1000
    if bytes > max_bytes
      echo printf("Too many debugging symbols selected (%d vs limit %d).", bytes, max_bytes)
      call init#CustomBottomBuffer('Found objects', files)
      return
    endif

    let remote_dir = g:HOST . ":/usr/lib/.debug"
    call init#SystemOrThrow(printf("rsync -lt %s %s", join(files), remote_dir))
    echo printf("Synced %d symbols!", len(files))
  endif
  call init#CustomBottomBuffer("Debug symbols", files)
endfunction

function! s:PlotTrace(name)
  if stridx(g:DEVICE, "onyx") >= 0
    let dir = "/tmp/rock-tracing"
  elseif stridx(g:DEVICE, "rockx") >= 0
    let dir = "/tmp/obsidian-profiling"
  else
    return init#Warn("Unknown device")
  endif
  let trace_txt = init#SystemOrThrow(printf("ssh %s ls -t %s", g:HOST, dir))
  if empty(trace_txt)
    echo "No trace"
    return
  endif

  let trace_txt = trace_txt[0]
  let parse_input = "~/Downloads/tracing/input/" .. a:name
  let parse_output = printf("~/Downloads/tracing/output/%s",  a:name)
  let plot_input = printf("~/Downloads/tracing/output/%s/%s", a:name, fnamemodify(trace_txt, ":r"))
  let plot_output = "~/Downloads/tracing/plot/" .. a:name

  if g:BUILD_TYPE != "Release"
    call init#Warn("Build type is %s.", g:BUILD_TYPE)
  endif

  if !isdirectory(expand("~/tracing_venv"))
    let errors = ["You do not have a python venv set up! You can run (at your own risk):"]
    call add(errors, "python -m venv tracing_venv")
    call add(errors, "source tracing_venv/bin/activate")
    call add(errors, "cd ~/libalcatraz/tracing/scripts/")
    call add(errors, "python -m pip install requirements.txt")
    return init#ShowErrors(errors)
  endif

  let cmds = []
  call add(cmds, "mkdir -p " .. parse_input)
  call add(cmds, "mkdir -p " .. plot_output)
  call add(cmds, printf("scp %s:%s/%s %s", g:HOST, dir, trace_txt, parse_input))
  call add(cmds, "source ~/tracing_venv/bin/activate")
  call add(cmds, printf("python3 parse.py -i %s -o %s", parse_input, parse_output))
  call add(cmds, printf("python3 plot_benchmark.py %s %s", plot_output, plot_input))
  botr split
  lcd ~/libalcatraz/tracing/scripts
  enew
  throw string(cmds)
  " call init#Termopen(join(cmds, " && "))
endfunction

function! s:BarfPlotTrace(name)
  let trace_txt = systemlist(printf("ssh %s ls -t /tmp | grep debug-info-", g:HOST))
  if empty(trace_txt)
    echo "No trace"
    return
  endif
  let trace_txt = trace_txt[0]

  if g:BUILD_TYPE != "Release"
    call init#Warn("Build type is %s.", g:BUILD_TYPE)
  endif

  echo "Removing extra columns from file..."
  let parse_input = "~/Downloads/bf_tracing/input/" .. a:name
  let parse_output = printf("~/Downloads/bf_tracing/output/%s",  a:name)
  let plot_input = printf("~/Downloads/bf_tracing/output/%s/%s", a:name, fnamemodify(trace_txt, ":r"))
  let plot_output = "~/Downloads/bf_tracing/plot/" .. a:name

  let cmds = []
  call add(cmds, "mkdir -p " .. parse_input)
  call add(cmds, "mkdir -p " .. plot_output)
  call add(cmds, printf("scp %s:/tmp/%s %s", g:HOST, trace_txt, parse_input))
  call init#SystemOrThrow(join(cmds, ";"))

  let local_txt = expand(printf("%s/%s", parse_input, trace_txt))
  let lines = readfile(local_txt)
  call filter(lines, 'v:val =~# " frame_id:\\| start_timestamp:\\| end_timestamp:\\|^a\\|^$"')
  call writefile(lines, local_txt)
  " Clear message status
  echo

  let cmds = []
  call add(cmds, "source ~/tracing_venv/bin/activate")
  call add(cmds, printf("python3 parse.py -i %s -o %s", parse_input, parse_output))
  call add(cmds, printf("python3 plot_benchmark.py %s %s", plot_output, plot_input))
  botr split
  lcd ~/libalcatraz/tracing/scripts
  enew
  call init#Termopen(join(cmds, " && "))
endfunction

function! s:OpenCV()
  let file = printf("~/libalcatraz/%s/memory/libalcatraz_opencv_mat.so.1.0.0", g:BUILD_TYPE)
  let file = fnamemodify(file, ":p")
  if !filereadable(file)
    echo "Preload library not found!"
    return
  endif
  let ago = init#PrettyTime(localtime() - getftime(file))
  let cmds = []
  call add(cmds, printf("echo Copying over library from %s ago", ago))
  call add(cmds, printf("cp ~/libalcatraz/%s/memory/libalcatraz_opencv_mat.so* %s/sysroots/armv8a-aisys-linux/usr/lib", g:BUILD_TYPE, g:SDK_DIR))
  call add(cmds, printf("scp ~/libalcatraz/%s/memory/libalcatraz_opencv_mat.so* %s:/usr/lib", g:BUILD_TYPE, g:HOST))
  call add(cmds, printf("ssh %s chmod +s /usr/lib/libalcatraz_opencv_mat.so*", g:HOST))
  bot sp
  enew
  call init#Termopen(join(cmds, ";"))
endfunction

function! s:MemoryMonitor(...)
  let tool = init#RemoteFindFiles(g:HOST, "backtrace_tool")
  if empty(tool)
    throw "Not found: backtrace_tool"
  endif
  let tool = tool[0]

  let input = systemlist(["ssh", g:HOST, "ls -t /tmp"])
  if empty(input)
    throw "No files found in /tmp!"
  endif
  if a:0 > 0
    call filter(input, 'stridx(v:val, a:1) >= 0')
  endif
  if empty(input)
    echo "Nothing to show!"
    return
  endif
  let input = "/tmp/" .. input[0]

  let executable = printf("%s/%s/application/obsidian-video", g:RSYNC_DIR, g:BUILD_TYPE)

  let cmd = printf("%s %s -e=%s", tool, input, executable)
  echo printf('Running tool on %s..', input)
  let lines = init#SystemOrThrow(["ssh", g:HOST, cmd])
  call init#CustomBottomBuffer('Memory report', lines)
  mode
endfunction

function! s:EnableCore()
  call init#SystemOrThrow(["ssh", g:HOST, '/usr/bin/bash -c "echo 1 > /proc/sys/fs/suid_dumpable"'])
  call init#ToClipboard("cd /tmp && ulimit -c unlimited")
endfunction

function! s:CheckHealth()
  let cmd = "redis-cli -s /run/ctlsys/redis.sock publish device-health:print 1"
  call system(["ssh", g:HOST, cmd])
endfunction

function s:GetTargets()
  " Note: Ordered by priority
  let targets = [
          \ ["/home/stef/libalcatraz", "master", "libalcatraz_git.bb"],
          \ ["/home/stef/alcatraz-ml-library", "main", "alcatraz-ml_git.bb"],
          \ ["/home/stef/device-health", "main", "device-health_git.bb"]]
  call add(targets, ["/home/stef/rock-video", "master", "rock-video_git.bb"])
  call add(targets, ["/home/stef/obsidian-video", "main", "obsidian-video_git.bb"])
  call add(targets, ["/home/stef/bd-video", "main", "bd-video_git.bb"])
  call add(targets, ["/home/stef/badge-and-face", "obsidian-master", "badge-and-face_git.bb"])
  return targets
endfunction

function! s:Bb()
  call s:AddRepo(FugitiveWorkTree())
endfunction

function! s:OpenBitbake(repo)
  let repo = a:repo
  let targets = filter(s:GetTargets(), 'v:val[0] == repo')
  if empty(targets)
    throw "Invalid repo: " .. repo
  endif

  let bitbake = targets[0][2]
  " Find old hash
  let files = qsearch#GetFiles(g:AIDISTRO, "-regex", ".*" .. bitbake)
  if empty(files)
    throw "Could not find: " .. bitbake
  endif
  if len(files) > 1
    throw "Multiple results for : " .. bitbake
  endif
  exe "e " .. files[0]
  if search("SRCREV") == 0
    throw "Failed to find SRCREV"
  endif
endfunction

function! s:AddRepo(repo)
  let repo = a:repo
  let targets = filter(s:GetTargets(), 'v:val[0] == repo')
  if empty(targets)
    throw "Invalid repo: " .. repo
  endif

  let new_src_branch = git#GetBranch(repo)
  if empty(new_src_branch)
    throw "Failed to determine branch!"
  endif
  let remote_rev = git#HashOrThrow("origin/" .. new_src_branch)
  let new_src_rev = git#HashOrThrow(new_src_branch)
  if remote_rev != new_src_rev
    throw "Unpushed changes!"
  endif

  call s:OpenBitbake(a:repo)

  call setline('.', 'SRCREV ?= "' .. new_src_rev .. '"')
  if search("SRCBRANCH") == 0
    throw "Failed to find SRCBRANCH"
  endif
  call setline('.', 'SRCBRANCH ?= "' .. new_src_branch .. '"')
  write
endfunction

function! s:FactoryReset()
  botr split
  enew
  call init#Termopen("ssh " .. g:HOST .. " touch /run/factory-reset/initiate-reset")
endfunction

function! s:Enroll()
  let cmds = []
  call add(cmds, 'redis-cli SET config:device.role "\"one-fa\""' )
  call add(cmds, 'redis-cli SET config:enrollment.enabled true' )
  call add(cmds, 'redis-cli SET config:enrollment.min_time 5' )
  call add(cmds, 'redis-cli SET config:enrollment.respect_acs false' )
  call systemlist(["ssh", g:HOST, join(cmds, ";")])
  if !v:shell_error
    call s:SshTerminal()
    echo "Please run mcu-inject-badge!"
  endif
endfunction

function! s:Reboot()
  let cmds = []
  call add(cmds, printf("ssh %s reboot", g:HOST))
  call add(cmds, "echo Waiting for reboot...")
  call add(cmds, "ssh_wait_silent " .. g:HOST)
  bot sp
  enew
  call init#Termopen(join(cmds, ";"))
endfunction

command! -nargs=0 Reboot call s:Reboot()

command -nargs=* -complete=customlist,DoCompl Do call init#Dispatch("Do", expand("<SID>"), <f-args>)
"}}}

""""""""""""""""""""""""""""AI"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#CommitAI()
  exe "e " .. g:AIDISTRO
  let cmd = ["diff", "--name-only", "--cached"]
  let staged = git#ExecuteOrThrow(cmd, "Cannot determine what changed in " .. g:AIDISTRO)
  for [repo, branch, bitbake] in reverse(s:GetTargets())
    let staged_bitbake = filter(copy(staged), 'stridx(v:val, bitbake) >= 0')
    if empty(staged_bitbake)
      continue
    endif
    " Get commit message. This is needed to create the branch and the commit
    exe "e " .. g:AIDISTRO
    let cmd = [FugitiveExtractGitDir(repo), "log", "-1", "--format=%B", "origin/" .. branch]
    let msg = git#ExecuteOrThrow(cmd, "Cannot determine commit message for " .. repo)[0]
    let issue = matchstr(msg, 'SW-[0-9]\{4\}')
    " Create branch
    exe "e " .. g:AIDISTRO
    if empty(issue)
      let ai_branch = "stef/ai"
    else
      let ai_branch = "stef/" .. issue .. "/ai"
    endif
    let cmd = ["checkout", "-b", ai_branch]
    call git#ExecuteOrThrow(cmd, "Failed to create branch " .. ai_branch)
    let ai_msg = fnamemodify(repo, ':t') .. ": " .. msg
    call git#ExecuteOrThrow(["commit", "-m", ai_msg])
    " Success
    exe "Gdrop " .. ai_branch
    return
  endfor
  throw "No changes detected!"
endfunction

function! work#TestAI()
  call s:BuildImage()
endfunction

function! work#PushAI()
  exe "e " .. g:AIDISTRO
  call git#ExecuteOrThrow(["push", "origin", "HEAD"], "Failed to push branch to origin")
  call init#ToClipboard("https://gitlab.com/Rainbe/Firmware/aidistro/-/merge_requests")
endfunction

function! work#CleanUpAI()
  exe "e " .. g:AIDISTRO
  let branch = git#GetBranchOrThrow()
  call git#ExecuteOrThrow(["checkout", "master"], "Failed to checkout master")
  " Not the end of the world if this fails.
  call git#ExecuteOrThrow(["reset", "--hard"])
  call git#ExecuteOrThrow(["pull", "origin", "master"], "Failed to pull new changes")
  call git#ExecuteOrThrow(["branch", "-D", branch], "Failed to delete newly created branch")
  let issue = matchstr(branch, 'SW-[0-9]\{4\}')
  if !empty(issue)
    call work#OpenJira(issue)
  endif
endfunction

function! work#ResetAI()
  exe "e " .. g:AIDISTRO
  call git#ExecuteOrThrow(["reset", "--hard"])
  call git#ExecuteOrThrow(["submodule", "update", "--init", "--recursive"])
  if !git#IsClean()
    echo "Failed to reset to a clean state"
    G
  endif
endfunction

function! AiCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let items = ["Commit", "Test", "Push", "CleanUp", "Reset"]
  return filter(items, 'v:val =~ a:ArgLead')
endfunction

command! -nargs=1 -complete=customlist,AiCompl AI call init#TryCall("work#" .. <q-args> .. "AI")
cabbr Ai AI
" }}}

""""""""""""""""""""""""""""Copy"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#OpenJira(issue)
  if !empty(a:issue)
    call init#ToClipboard("https://alcatrazai.atlassian.net/browse/" .. a:issue)
  endif
endfunction

function! work#OpenMergeRequest(arg)
  if empty(a:arg)
    call work#GenerateMergeRequestURL(FugitiveWorkTree())
  else
    call qutil#GetRepos()->qutil#CommandPass(a:arg)->qutil#CreateOneShotQuickfix("Repos", 'work#GenerateMergeRequestURL')
  endif
endfunction

function! work#GenerateMergeRequestURL(repo)
  let git_dir = a:repo .. "/.git"
  let url = git#ExecuteOrThrow([git_dir, 'remote', 'get-url', 'origin'])[0]
  let url = substitute(url, '^git@gitlab.com:', 'https://gitlab.com/', '')
  let url = substitute(url, '\.git$', '', '')
  let url ..= '/-/merge_requests'
  call init#ToClipboard(url)
endfunction

function! s:CopyJira()
  call init#ToClipboard("https://alcatrazai.atlassian.net/jira/your-work")
endfunction

function! s:CopyJenkins()
  call init#ToClipboard("https://jenkins.alcatraz.ai/")
endfunction

function! s:CopySlack()
  call init#ToClipboard("https://app.slack.com/client/T10SACYGL/dms")
endfunction

function! s:CopyBranch()
  call init#ToClipboard(git#GetBranch())
endfunction

function! s:CopyHash()
  let hash = git#ExecuteOrThrow(['rev-parse', 'HEAD'], "Failed to parse HEAD")
  call init#ToClipboard(hash[0])
endfunction

function! s:CopyFilename()
  call init#ToClipboard(expand("%:p"))
endfunction

function! s:CopyBasename()
  call init#ToClipboard(expand("%:t"))
endfunction

function! s:CopyDirectory()
  call init#ToClipboard(getcwd())
endfunction

function! s:CopyIp()
  call init#ToClipboard(g:HOST_IP)
endfunction

function CopyCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let cmds = ["Jira", "Jenkins", "Slack", "Branch", "Hash", "Filename", "Basename", "Directory", "Ip"]
  return filter(cmds, 'v:val =~? a:ArgLead')
endfunction

command! -nargs=1 -complete=customlist,CopyCompl Copy call init#Dispatch('Copy', '<SID>Copy', <q-args>)

" }}}

""""""""""""""""""""""""""""Orientation"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:Orientation(deg)
  sp
  Ssfs /usr/share/obsidian-video/cfg/default.json
  let old_pos = search('"orientation"')
  if empty(a:deg)
    if old_pos <= 0
      echo "Orientation missing (0 degrees)."
    else
      if stridx(getline('.'), "right") >= 0
        echo "Orientation right (0 degrees)."
      elseif stridx(getline('.'), "flat") >= 0
        echo "Orientation flat (90 degrees)."
      elseif stridx(getline('.'), "left") >= 0
        echo "Orientation flat (180 degrees)."
      elseif stridx(getline('.'), "bottom") >= 0
        echo "Orientation flat (270 degrees)."
      else
        echo "Orientation unknown!"
      endif
    endif
    quit
    return
  endif

  if old_pos > 0
    call deletebufline(bufnr(), old_pos)
  endif
  let pos = search('"version"')
  if a:deg == 0
    let deg = "right"
  elseif a:deg == 90
    let deg = "flat"
  elseif a:deg == 180
    let deg = "left"
  elseif a:deg == 270
    let deg = "bottom"
  else
    echo "Invalid degrees!"
    return ''
  endif
  let config = printf('  "orientation": "%s",', deg)
  call append(pos, config)
  write
  quit
endfunction

command! -nargs=? Orientation call s:Orientation(<q-args>)
"}}}

""""""""""""""""""""""""""""Services"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:OpenServices()
  let services = s:GetServices()
  let nr = qutil#CreateCustomQuickfix(services, 'Services', expand("<SID>") .. 'OnSelectedService')
  call s:UpdateServicesHl(nr)
endfunction

function s:OnSelectedService()
  let pos = line('.')
  let service = getline(pos)
  let status = get(s:services_status, service, "")
  if status == "inactive" || status == "failed"
    call init#Jobstart(["ssh", g:HOST, "systemctl start " .. service])
  else
    let cmds = []
    if status != "active"
      call init#Warn("Status was %s.", status)
      call add(cmds, "systemctl disable " .. service)
    endif
    call add(cmds, "systemctl stop " .. service)
    call init#Jobstart(["ssh", g:HOST, join(cmds, ";")])
  endif
endfunction

function! s:StopServiceMonitor()
  if exists('s:services_job')
    if jobstop(s:services_job)
      call jobwait([s:services_job])
    endif
    unlet s:services_job
  endif
endfunction

function! s:StartServiceMonitor(initial_activity)
  call s:StopServiceMonitor()
  " XXX: Potential race condition but it makes the code look nicer so it's okay.
  let services = s:GetServices()
  let activity = filter(a:initial_activity, '!empty(v:val)')
  if len(activity) != len(services)
    " Possible if device is down.
    return init#Warn("Unknown state of some services!")
  endif
  let s:services_status = #{}
  for idx in range(len(services))
    let s:services_status[services[idx]] = activity[idx]
  endfor

  let cmd = [
        \ "dbus-monitor",
        \ "--system",
        \ string("type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.freedesktop.systemd1.Unit'")]
  let s:services_job = init#Jobstart(["ssh", g:HOST, join(cmd)], #{on_stdout: expand("<SID>") .. 'OnServicesChanged'})
endfunction

function! work#ServicesStatus()
  if !exists('s:services_status')
    echo "No services monitored!"
    return
  endif

  let lines = []
  for service in keys(s:services_status)
    let line = printf("%s: %s", service, s:services_status[service])
    call add(lines, line)
  endfor
  let nr = init#CustomBottomBuffer('Services', lines)
endfunction

function s:OnServicesChanged(_0, d, _1)
  for idx in range(len(a:d))
    let line = a:d[idx]
    if stridx(line, "path=/org/freedesktop/systemd1/unit/") >= 0
      let dbus_name = matchstr(line, 'unit/\zs[^;]*')
      let service_name = substitute(dbus_name, '_2d', '-', 'g')
      let service_name = substitute(service_name, '_2e', '.', 'g')
      let s:services_last = service_name
    elseif stridx(line, 'string "ActiveState"') >= 0
      let next_line = get(a:d, idx + 1, '')
      let activity = matchstr(next_line, 'string "\zs[^"]\+\ze"')
      if exists('s:services_last') && has_key(s:services_status, s:services_last)
        let changed = s:services_status[s:services_last] != activity
        if changed
          let s:services_status[s:services_last] = activity
          let nr = bufnr("Services")
          if init#IsVisible(nr)
            call s:UpdateServicesHl(nr)
          else
            call init#Warn("Service %s is %s!", s:services_last, activity)
          endif
        endif
      endif
    endif
  endfor
endfunction

function! s:UpdateServicesHl(nr)
  let services = getbufline(a:nr, 1, '$')
  let ns = nvim_create_namespace('services')
  for idx in range(len(services))
    let activity = s:services_status[services[idx]]
    let extmarks = nvim_buf_get_extmarks(a:nr, ns, [idx, 0], [idx, 0], #{details: 1})
    if !empty(extmarks)
      call nvim_buf_del_extmark(a:nr, ns, extmarks[0][0])
    endif
    if activity == 'active'
      call nvim_buf_set_extmark(a:nr, ns, idx, 0, #{line_hl_group: 'DiagnosticOk'})
    elseif activity == 'inactive'
      call nvim_buf_set_extmark(a:nr, ns, idx, 0, #{line_hl_group: 'DiagnosticUnnecessary'})
    else
      call nvim_buf_set_extmark(a:nr, ns, idx, 0, #{line_hl_group: 'Normal'})
    endif
  endfor
endfunction

command! -nargs=0 Health call s:OpenServices()
"}}}

""""""""""""""""""""""""""""RTSP"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function work#CheckRtspConnection(bang, ip)
  if !executable("nc")
    echom "nc is not executable (package netcat)"
    return
  endif
  if !empty(a:ip)
    let ip = a:ip
  else
    let ip = g:HOST_IP
  endif

  call systemlist(["ping", "-c", "1", ip])
  if v:shell_error
    return init#Warn("No connection to " .. ip)
  endif
  call system(["nc", "-w", "1", "-z", ip, 8554])
  if v:shell_error
    return init#Warn("Port 8554 is not open!")
  endif

  call system(["nc", "-w", "1", "-z", ip, 8554])

  let cmd = "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n"
  let output = systemlist(printf("timeout 0.1 nc %s 8554", ip), cmd)
  if stridx(join(output), "DESCRIBE") < 0
    call init#ShowErrors(output)
    return init#Warn("No DESCRIBE command!")
  endif

  if stridx(g:DEVICE, "onyx") >= 0
    let streams = ["ircamera", "mircamera", "depthcamera", "mdepthcamera", "rgbcamera", "mrgbcamera"]
  elseif stridx(g:DEVICE, "rockx") >= 0
    let streams = ["adaptive_h264", "adaptive_mjpeg", "near-rtsp", "far-rtsp", "center-rtsp", "intercom"]
  endif

  let cmd = ""
  let seq = 2
  for stream in streams
    let cmd .= printf("DESCRIBE rtsp://%s:8554/%s RTSP/1.0\r\n", ip, stream) .
          \ printf("CSeq: %d\r\n", seq) .
          \ "Accept: application/sdp\r\n" .
          \ "\r\n"
    let seq += 1
  endfor

  let output = system(printf("timeout 4 nc %s 8554", ip), cmd)
  let output = split(output, "\r\n")

  let ok = filter(copy(output), 'v:val =~# "RTSP/[0-9.]* 200 OK"')
  if empty(ok) || !empty(a:bang)
    echo printf("Found %d streams", len(ok))
    return init#CustomBottomBuffer("RTSP", output)
  endif

  let content_base = filter(copy(output), 'v:val =~# "^Content-Base:"')
  let rtpmap = filter(copy(output), 'v:val =~# "^a=rtpmap"')
  if len(ok) != len(content_base) || len(ok) != len(rtpmap)
    return init#Warn("Parse error")
  endif

  let found_streams = []
  for i in range(len(ok))
    let stream = matchstr(content_base[i], '/\zs[^/]\+\ze/\?$')
    if stridx(rtpmap[i], "H264") >= 0
      call add(found_streams, "H264: " . stream)
    elseif stridx(rtpmap[i], "JPEG") >= 0
      call add(found_streams, "MJPEG: " . stream)
    else
      call init#Warn("Unknown encoder: %s", rtpmap[i])
    endif
  endfor

  call qutil#CreateCustomQuickfix(found_streams, 'Streams', 'work#SelectStream', ip)
endfunction

function work#SelectStream(ip)
  let pos = line('.')
  let line = getline(pos)
  let [type, name] = split(line, ": ")
  if type == "H264"
    let fmt = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/%s latency=100 ! rtph264depay ! h264parse ! avdec_h264 ! fpsdisplaysink video-sink=autovideosink"
  elseif type == "MJPEG"
    let fmt = "gst-launch-1.0 rtspsrc location=rtsp://%s:8554/%s latency=0 ! rtpjpegdepay ! jpegparse ! avdec_mjpeg ! fpsdisplaysink video-sink=autovideosink"
  endif
  let msg = printf(fmt, a:ip, name)
  call init#ToClipboard(msg)
endfunction

command! -bang -nargs=? Rtsp call work#CheckRtspConnection("<bang>", <q-args>)
"}}}

""""""""""""""""""""""""""""Redis"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:RedisGetUsers()
  let redis_cmd =
        \ "local u=redis.call([[SMEMBERS]],[[onvif.users.User]]) " .
        \ "local o={} " .
        \ "for _,h in ipairs(u) do " .
        \   "o[#o+1]=(redis.call([[HGET]],h,[[userName]]) or h)" .
        \   "..string.char(9).." .
        \   "(redis.call([[HGET]],h,[[password]]) or [[]]) " .
        \ "end " .
        \ "return table.concat(o,string.char(10))"
  let remote_cmd = printf("redis-cli -n 1 -s /run/redis/redis.sock EVAL '%s' 0", redis_cmd)
  let output = init#SystemOrThrow(["ssh", g:HOST, remote_cmd])
  call qutil#CreateOneShotQuickfix(output, 'Users', function("s:RedisUsersCb"))
endfunction

function! s:RedisUsersCb(credentials) 
  let [user, pw] = split(a:credentials)
  call init#ToClipboard(pw)
endfunction

function! s:ShowEncoderSettings(encoder)
  const encoder = "onvif.media.VideoEncoder#adaptive_H264"
  let remote_cmd = printf("redis-cli --raw -n 1 -s /run/redis/redis.sock HGETALL %s", a:encoder)
  let output = filter(init#SystemOrThrow(["ssh", g:HOST, remote_cmd]), '!empty(v:val)')
  let props = {}
  for i in range(0, len(output) - 1, 2)
    let props[output[i]] = output[i + 1]
  endfor

  let output = []

  call add(output, printf("name: %s", get(props, "name", '<nil>')))
  call add(output, '')

  for key in ["width", "height", "framerate"]
    call add(output, printf("%s: %s", key, get(props, key, '<nil>')))
  endfor
  call add(output, '')

  for key in ["multicastIPAddress", "multicastPort", "multicastTTL", "multicastEnable", "multicastautostart"]
    call add(output, printf("%s: %s", key, get(props, key, '<nil>')))
  endfor
  call add(output, '')

  call add(output, printf("token: %s", get(props, "token", '<nil>')))

  call init#CustomBottomBuffer('H264 options', output)
endfunction

function! s:RedisH264Encoder()
  const encoder = "onvif.media.VideoEncoder#adaptive_H264"
  call s:ShowEncoderSettings(encoder)
endfunction

function! s:RedisMJPEGEncoder()
  const encoder = "onvif.media.VideoEncoder#adaptive_JPEG"
  call s:ShowEncoderSettings(encoder)
endfunction

command! -nargs=* -complete=customlist,RedisCompl Redis call init#Dispatch("Redis", expand("<SID>Redis"), <f-args>)

function! RedisCompl(ArgLead, CmdLine, CursorPos)
  let nargs = len(split(a:CmdLine))
  if a:CursorPos < len(a:CmdLine) || nargs > 2
    return []
  endif
  let cmds = ["GetUsers", 'H264Encoder', 'MJPEGEncoder']
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

"}}}

""""""""""""""""""""""""""""Check"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function s:GetRepoStatus(repo, ...)
  let repo = FugitiveExtractGitDir(a:repo)
  if !git#IsClean(repo)
    return "Dirty."
  endif

  let branch = git#GetBranch(repo)
  if empty(branch)
    return "Detached HEAD."
  endif
  if a:0 > 0 && branch != a:1
    return printf("Checked out wrong branch '%s'.", branch)
  endif

  call git#ExecuteOrThrow([repo, "fetch", "origin", branch])

  let dict = git#ExecuteOrThrow([repo, "rev-list", "--left-right", "--count", printf("%s...origin/%s", branch, branch)])
  if dict['exit_status'] != 0
    return "Unknown remote branch!"
  endif

  let output = dict['stdout']
  if type(output) == v:t_list
    let output = join(output)
  endif
  let [ahead, behind] = split(output)
  if ahead != 0 || behind != 0
    if ahead == 0
      return printf("Branch is %d commits behind.", behind)
    elseif behind == 0
      return printf("Branch is %d commits ahead.", ahead)
    else
      return printf("Branch is %d ahead and %d behind.", ahead, behind)
    endif
  endif
  return v:null
endfunction

function s:CheckRepo(repo, ...)
  if a:0 > 0 && !empty(a:1)
    let status = s:GetRepoStatus(a:repo, a:1)
  else
    let status = s:GetRepoStatus(a:repo)
  endif
  if !empty(status)
    call nvim_echo([[status, "Normal"]], v:false, #{})
  else
    let branch = git#GetBranch(a:repo)
    echo printf("%s is clean and up to date!", branch)
  endif
endfunction

function! s:ForceUpdateRepo(repo, ...)
  let repo = FugitiveExtractGitDir(a:repo)
  if a:0 > 0
    let branch = a:1
    call git#ExecuteOrThrow([repo, "reset", "--hard"])
    call git#ExecuteOrThrow([repo, "checkout", branch])
  else
    let branch = git#GetBranch(a:repo)
    if empty(branch)
      echo "Detached HEAD!"
      return
    endif
  endif

  let dict = FugitiveExecute([repo, "fetch", "origin", branch])
  if dict['exit_status'] == 0
    call git#ExecuteOrThrow([repo, "reset", "--hard", "origin/" .. branch])
  else
    call git#ExecuteOrThrow([repo, "reset", "--hard", branch])
  endif

  call git#UpdateSubmodule(repo)

  if !git#IsClean(repo)
    exe "split " .. a:repo
    let w = win_getid()
    G
    call win_execute(w, 'close')
    echo "Untracked files."
  else
    echo printf("%s is clean and up to date!", branch)
  endif
endfunction

function! s:CheckAidistro(bang, branch)
  let repo = g:AIDISTRO
  if empty(a:bang)
    call s:CheckRepo(repo, a:branch)
  elseif empty(a:branch)
    call s:ForceUpdateRepo(repo)
  else
    call s:ForceUpdateRepo(repo, a:branch)
  endif
endfunction

function! AidistroCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  return git#GetRefs('refs/heads/', a:ArgLead, g:AIDISTRO)
endfunction

command! -bang -nargs=? -complete=customlist,AidistroCompl Aidistro call s:CheckAidistro("<bang>", <q-args>)

function! s:ShowRepoStatus(pat)
  let list = []
  let targets = add(s:GetTargets(), [g:AIDISTRO, "master", ""])
  let targets = filter(targets, "stridx(v:val[0], a:pat) >= 0")
  for [repo, branch, _] in targets
    let status = s:GetRepoStatus(repo, branch)
    if empty(status)
      let status = "OK"
    endif
    let short_repo = fnamemodify(repo, ':t')
    call add(list, printf("%s: %s", short_repo, status))
  endfor
  call qutil#CreateCustomQuickfix(list, "Check", "work#FixRepoStatus")
endfunction

function work#FixRepoStatus()
  let line = line('.')
  let short_repo = split(getline('.'), ":")[0]
  let targets = add(s:GetTargets(), [g:AIDISTRO, "master", ""])
  let targets = filter(targets, "stridx(v:val[0], short_repo) >= 0")
  call assert_true(len(targets) == 1)
  let [repo, branch; _] = targets[0]
  call s:ForceUpdateRepo(repo, branch)
  " Update status
  let status = s:GetRepoStatus(repo, branch)
  if empty(status)
    let status = "OK"
  endif
  call setline(line, printf("%s: %s", short_repo, status))
endfunction

command! -nargs=? -complete=customlist,CheckCompl Check call s:ShowRepoStatus(<q-args>)

function! CheckCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let repos = map(s:GetTargets(), "v:val[0]")
  call add(repos, g:AIDISTRO)
  let repos = filter(repos, 'stridx(v:val, a:ArgLead) >= 0')
  return map(repos, 'fnamemodify(v:val, ":t")')
endfunction
"}}}

""""""""""""""""""""""""""""Mender"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function s:DetermineImage()
  let artifact = init#SystemOrThrow(["ssh", g:HOST, "mender show-artifact"])
  let commitish = matchstr(artifact[0],  '-g\([0-9a-f]\+\)')[2:]
  if empty(commitish)
    echo "Operation failed."
    return
  endif
  exe "Repo " .. g:AIDISTRO
  let aidistro_commitish = git#HashOrThrow("HEAD")
  let len = min([len(aidistro_commitish), len(commitish)])
  if aidistro_commitish[:len-1] != commitish[:len-1]
    call init#Warn(printf("Commit differs from %s!", g:AIDISTRO))
  else
    echo "Commit matched with " .. g:AIDISTRO
  endif
  exe printf("G log %s -n 10", commitish)
  silent only
endfunction

command -nargs=0 Artifact call s:DetermineImage()
command -nargs=0 Mender call s:DetermineImage()

function s:DetermineRsyncDir()
  let cmd = "df -h --output=fstype,avail,target | tail +2 | sort -r -h -k2"
  call init#OnJobOutput(["ssh", g:HOST, cmd], 'work#OnDiskFree')
endfunction

function work#OnDiskFree(fs)
  let fs = filter(a:fs, '!empty(v:val)')
  if empty(fs)
    return init#Warn("Will not update RSYNC directory! No mounts detected!")
  endif
  const blacklist_fs = "nfs"
  call filter(fs, 'stridx(split(v:val)[0], blacklist_fs) < 0')
  " Try to auto-detecting
  const target = "/dev/shm"
  let res = filter(copy(fs), 'stridx(v:val, target) >= 0')
  if len(res) > 0
    call assert_true(len(res) == 0)
    return work#OnFilesystem(res[0])
  endif
  call qutil#CreateOneShotQuickfix(fs, "Choose RSYNC directory", "work#OnFilesystem")
endfunction

function work#OnFilesystem(entry)
  let [source, avail, target] = split(a:entry)
  let g:RSYNC_DIR = target
  if stridx(avail, "G") < 0
    call init#Warn("Have for %s g:RSYNC_DIR", avail)
  endif
endfunction

function s:CheckMenderCommit()
  call init#OnJobExit(["ssh", g:HOST, "test -f /var/lib/mender/upgrade_available"], 'work#OnCheckUpdate')
endfunction

function work#OnCheckUpdate(code)
  if a:code == 0
    call init#Warn("Uncommited changes with mender!")
  endif
endfunction
"}}}

""""""""""""""""""""""""""""Gitlab"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

let g:gitlab_token_file = stdpath('state') .. "/gitlab_token.txt"
if filereadable(g:gitlab_token_file)
  let g:gitlab_token = readfile(g:gitlab_token_file)[0]
  let today = strftime('%Y-%m-%d')
  if today ># '2027-04-20'
    call init#Warn("Your gitlab token has expired!")
  endif
else
  call init#Warn("No gitlab token set up!")
  let g:gitlab_token = ""
endif

function! work#OnGitlabResponse(req, cb)
  let cmd = ["curl", "--silent", "--header", "PRIVATE-TOKEN:" .. g:gitlab_token, a:req]
  return init#OnJobOutput(cmd, function("s:DecodeJsonResponse", [a:cb]))
endfunction

function! s:DecodeJsonResponse(cb, output)
  call assert_true(len(a:output) <= 1)
  if len(a:output) >= 1
    let dict = empty(a:output[0]) ? #{} : json_decode(a:output[0])
    call function(a:cb)(dict)
  endif
endfunction

function! work#GitlabRequest(req)
  let cmd = ["curl", "--silent", "--header", "PRIVATE-TOKEN:" .. g:gitlab_token, a:req]
  return init#SystemOrThrow(cmd)
endfunction

function! work#OnGitlabUser(cb)
  if !exists('g:gitlab_user')
    call work#OnGitlabResponse("https://gitlab.com/api/v4/user", function("s:OnGitlabUser", [a:cb]))
  else
    call function(a:cb)()
  endif
endfunction

function! s:OnGitlabUser(cb, user)
  let g:gitlab_user = a:user["id"]
  call function(a:cb)()
endfunction

function! work#OpenMergeRequstQuickfix(bang)
  call work#OnGitlabUser(function("s:OnMyMergeRequests", [a:bang]))
endfunction

function! s:OnMyMergeRequests(bang)
  let field = empty(a:bang) ? "author_id" : "assignee_id"
  let req = printf("https://gitlab.com/api/v4/merge_requests?scope=all&%s=%s&state=opened&per_page=100", field, g:gitlab_user)
  call work#OnGitlabResponse(req, function("s:OnMergeRequestDict", [req]))
endfunction

function s:CompareTimestamps(lhs, rhs)
  if a:lhs.timestamp < a:rhs.timestamp
    return -1
  elseif a:lhs.timestamp > a:rhs.timestamp
    return 1
  else
    return 0
  endif
endfunction

function! s:OnMergeRequestDict(req, dict)
  const only_other_reviews = stridx(a:req, "author_id") < 0
  let list = []
  for entry in a:dict
    if only_other_reviews && entry["author"]["id"] == g:gitlab_user
      continue
    endif
    let repo = matchstr(entry["web_url"], '/\zs[^/]\+\ze/-/merge_requests')
    let targets = filter(s:GetTargets(), "stridx(v:val[0], repo) >= 0")
    let item = #{
          \ title: entry["title"],
          \ repo_id: entry["project_id"],
          \ mr_id: entry["iid"],
          \ timestamp: entry["created_at"],
          \ repo: repo,
          \ url: entry["web_url"],
          \ branch: entry["source_branch"],
          \ target_branch: entry["target_branch"]
          \ }
    if len(targets) >= 1
      let item["repo_full"] = targets[0][0]
    endif
    call add(list, item)
  endfor

  call sort(list, function("s:CompareTimestamps"))
  let lines = map(copy(list), "printf('[%s] %s', v:val.repo, v:val.title)")
  let nr = qutil#CreateCustomQuickfix(lines, "Gitlab", function("s:ShowMergeRequestHelp"))
  call setbufvar(nr, 'mr_list', list)
  nnoremap <silent> <buffer> B :call <SID>CheckoutMergeRequest()<CR>
  nnoremap <silent> <buffer> b :call <SID>GetBranchMergeRequest()<CR>
  nnoremap <silent> <buffer> w :call <SID>GetMergeRequestURL()<CR>
  nnoremap <silent> <buffer> n :call <SID>ShowNotesMergeRequest()<CR>
  nnoremap <silent> <buffer> T :call <SID>WorktreeMergeRequest()<CR>
endfunction

function s:ShowMergeRequestHelp()
  echo "(B) Reset repo to branch locally (T) Edit in worktree (b) Copy branch (w) Open URL (n) Show notes"
endfunction

function! s:GetMergeRequestURL()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  call init#ToClipboard(entry["url"])
  " quit
endfunction

function! s:CheckoutMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  let repo = entry["repo_full"]
  call s:ForceUpdateRepo(repo, entry["branch"])
  quit
  exe "e " .. repo
endfunction

function! s:GetBranchMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  call init#ToClipboard(entry["branch"])
endfunction

function! s:ShowNotesMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  let req = printf("https://gitlab.com/api/v4/projects/%s/merge_requests/%s/notes?per_page=100",
        \ entry["repo_id"], entry["mr_id"])

  let repo = entry["repo_full"]
  call work#OnGitlabResponse(req, function("s:ShowGitlabNotes", [repo]))
endfunction

function! s:WorktreeMergeRequest()
  let idx = line('.') - 1
  let entry = b:mr_list[idx]
  let repo = entry["repo_full"]
  let branch = entry["branch"]
  let target_branch = entry["target_branch"]


  let git_dir = FugitiveExtractGitDir(repo)
  call git#CloseWorktree()
  call git#ExecuteOrThrow([git_dir, "fetch", "origin", branch])

  call git#TrackBranch("!", branch, git_dir)
  call git#OpenWorktree(branch, repo, #{preview: 1, on_success: function("s:OnMergeRequestWorktree", [target_branch])})
endfunction

function! s:OnMergeRequestWorktree(target_branch)
  const path = git#WorktreePath()
  exe "e " .. path
  only
  call init#SystemOrThrow(["git", "fetch", "origin", a:target_branch])
  exe "R origin/" .. a:target_branch
endfunction

function! s:ShowGitlabNotes(repo, resp)
  let head = git#HashOrThrow("HEAD", a:repo)
  let list = []
  for note in a:resp
    let resolvable = get(note, "resolvable", v:false)
    let resolved = get(note, "resolved", v:true)
    let text = note["body"]
    let pos = get(note, "position", #{})
    if resolvable && !resolved && !empty(pos)
      let start = pos["line_range"]["start"]
      let line = pos["new_line"]
      let file = printf("%s/%s", a:repo, pos["new_path"])
      let sha = pos["head_sha"]
      if sha != head
        let url = FugitiveFind(printf("%s:%s", sha, file))
      else
        let url = file
      endif
      let timestamp = note["created_at"]
      let author = note["author"]["username"]
      let text = printf("%s: %s", author, text)
      call add(list, #{filename: url, lnum: line, text: text, timestamp: timestamp})
    endif
  endfor
  call sort(list, function("s:CompareTimestamps"))
  call qutil#SetQuickfix(list, "Notes")
endfunction

function! s:MrCommand(bang, arg)
  if !empty(a:arg)
    if empty(a:bang)
      call work#OpenMergeRequest(a:arg)
    else
      return init#Warn("Bang is not allowed in this context!")
    endif
  else
    call work#OpenMergeRequstQuickfix(a:bang)
  endif
endfunction

command! -nargs=? -bang -complete=customlist,qutil#ReposCompl Mr call s:MrCommand("<bang>", <q-args>)
cabbr MR Mr

function! s:CollectEveryUnmergedMr()
  let req = printf("https://gitlab.com/api/v4/merge_requests?assignee_id=%s&state=all&&per_page=100", g:gitlab_user)
  call work#OnGitlabResponse(req, function("s:OnEveryUnmergedMr"))
endfunction

function! s:OnEveryUnmergedMr(dict)
  let repo_to_branch = #{}
  for entry in a:dict
    let repo = matchstr(entry["web_url"], '/\zs[^/]\+\ze/-/merge_requests')
    let targets = filter(s:GetTargets(), "stridx(v:val[0], repo) >= 0")
    if len(targets) >= 1
      let repo = targets[0][0]
      let branch = entry["source_branch"]
      if branch == "obsidian-master"
        throw string(entry)
      endif
      if !has_key(repo_to_branch, repo)
        let repo_to_branch[repo] = #{}
      endif
      let repo_to_branch[repo][branch] = 1
    endif
  endfor
  let list = []
  let current_author = git#ExecuteOrThrow(["config", "user.name"])[0]
  for repo in keys(repo_to_branch)
    let git_dir = FugitiveExtractGitDir(repo)
    let cmd = [git_dir, "for-each-ref", "--sort=-committerdate", "refs/heads/", "--format=%(refname:short)"]
    let local_branches = git#ExecuteOrThrow(cmd)
    let remote_branches = repo_to_branch[repo]
    for branch in local_branches
      let targets = filter(s:GetTargets(), "stridx(v:val[0], repo) >= 0")
      let master_branch = len(targets) >= 1 ? targets[0][1] : ""
      if !has_key(remote_branches, branch) && branch != master_branch
        let author = git#ExecuteOrThrow([git_dir, "log", branch, "-1", "--pretty=%an"])[0]
        if author == current_author
          call add(list, printf("%s: %s", repo, branch))
        endif
      endif
    endfor
  endfor
  call qutil#CreateCustomQuickfix(list, "Unmerged", function("s:OnUnmergedBranch"))
endfunction

function! s:OnUnmergedBranch()
  let line = getline('.')
  let [repo, branch] = split(line, ": ")
  call s:ForceUpdateRepo(repo, branch)
  quit
  exe "e " .. repo
endfunction

command! -nargs=0 Unmerged call work#OnGitlabUser(function("s:CollectEveryUnmergedMr"))

function! s:CollectEveryMergedMr()
  let req = printf("https://gitlab.com/api/v4/merge_requests?assignee_id=%s&state=merged&&per_page=100", g:gitlab_user)
  call work#OnGitlabResponse(req, function("s:OnEveryMergedMr"))
endfunction

function! s:OnEveryMergedMr(dict)
  let items = []
  for entry in a:dict
    let repo = matchstr(entry["web_url"], '/\zs[^/]\+\ze/-/merge_requests')
    let title = entry["title"]
    let branch = entry["source_branch"]
    let timestamp = entry["merged_at"]
    let issue = work#ExtractIssue(branch)
    if empty(issue)
      let issue = work#ExtractIssue(title)
    endif
    call add(items, #{repo: repo, title: title, issue: issue, timestamp: timestamp})
  endfor
  call sort(items, function("s:CompareTimestamps"))
  call reverse(items)
  let issues = map(copy(items), "v:val.issue")
  let items = map(items, "printf('%s: %s', v:val.repo, v:val.title)")
  let nr = qutil#CreateCustomQuickfix(items, "Merged", function("s:OnMergedBranch"))
  call setbufvar(nr, "issues", issues)
endfunction

function! s:OnMergedBranch()
  let idx = line('.') - 1
  let issue = b:issues[idx]
  if !empty(issue)
    call work#OpenJira(issue)
  else
    echo "Unknown issue!"
  endif
endfunction

command! -nargs=0 Merged call work#OnGitlabUser(function("s:CollectEveryMergedMr"))

"}}}

""""""""""""""""""""""""""""Jenkins"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

let g:alcatraz_ai_user = "stefan@alcatraz.ai"
let g:jenkins_token_file = stdpath('state') .. "/jenkins_token.txt"
if filereadable(g:jenkins_token_file)
  let g:jenkins_token = readfile(g:jenkins_token_file)[0]
else
  call init#Warn("No jenkins token set up!")
  let g:jenkins_token = ""
endif

function! work#OnJenkinsResponse(req, cb)
  let credentials = printf("%s:%s", g:alcatraz_ai_user, g:jenkins_token)
  let cmd = ["curl", "--silent", "--globoff", "-u", credentials, a:req]
  return init#OnJobOutput(cmd, function("s:DecodeJsonResponse", [a:cb]))
endfunction

function s:ShowBuilds()
  let jobs = ["aidistro_p1", "aidistro_obsidian", "aidistro_obsidian_release"]
  let ns = "jenkins_builds"
  for job in jobs
    let req = printf(
          \ "https://jenkins.alcatraz.ai/job/%s/api/json?tree=builds[number,result,timestamp,building,url,actions[causes[userId]]]{,100}",
          \ job)
    let Cb = init#JoinCallbacks(ns, job, function("s:OnBuildsResponse"), len(jobs))
    call work#OnJenkinsResponse(req, Cb)
  endfor
endfunction

function! s:FindUserId(json)
  if type(a:json) == v:t_list
    for item in a:json
      let user_id = s:FindUserId(item)
      if !empty(user_id)
        return user_id
      endif
    endfor
  elseif type(a:json) == v:t_dict
    if has_key(a:json, "userId")
      return a:json["userId"]
    endif
    for v in values(a:json)
      let t = type(v)
      if t == v:t_list || t == v:t_dict
        let user_id = s:FindUserId(v)
        if !empty(user_id)
          return user_id
        endif
      endif
    endfor
  endif
  return ""
endfunction

function! s:OnBuildsResponse(response_list)
  let items = []
  for [job, json] in a:response_list
    for build in json["builds"]
      let user = s:FindUserId(build)
      if user != g:alcatraz_ai_user
        continue
      endif
      let timestamp = build["timestamp"] / 1000
      let today = strftime("%Y-%m-%d", timestamp) == strftime("%Y-%m-%d")
      let seconds = localtime() - timestamp
      if today
        let pretty_time = init#PrettyTime(seconds) .. " ago"
      else
        let pretty_time = strftime("%Y-%m-%d %H:%M:%S", timestamp)
      endif
      let name = printf("%s %s [%s]: %s", job, build["number"], build["result"], pretty_time)
      if build["building"]
        let hl = "DiagnosticUnnecessary"
      elseif build["result"] == "FAILURE"
        let hl = "DiagnosticError"
      elseif build["result"] == "SUCCESS"
        let hl = "DiagnosticOk"
      else
        let hl = "Normal"
      endif
      call add(items, #{name: name, timestamp: timestamp, url: build["url"], hl: hl})
    endfor
  endfor
  call sort(items, function("s:CompareTimestamps"))
  call reverse(items)
  let names = map(copy(items), "v:val.name")
  let nr = qutil#CreateCustomQuickfix(names, "Builds", function("s:OnSelectedBuild"))
  call setbufvar(nr, "urls", map(copy(items), "v:val.url"))
  let ns = nvim_create_namespace("builds")
  for idx in range(len(items))
    call nvim_buf_set_extmark(nr, ns, idx, 0, #{line_hl_group: items[idx]["hl"]})
  endfor
endfunction

function! s:OnSelectedBuild()
  let idx = line('.') - 1
  let url = b:urls[idx]
  call init#ToClipboard(url)
endfunction

command! -nargs=0 Builds call s:ShowBuilds()

function! work#OnJenkinsPost(req, data, cb)
  let credentials = printf("%s:%s", g:alcatraz_ai_user, g:jenkins_token)
  let cmd = [ "curl", "--silent", "-i", "--globoff", "-X", "POST", "-u", credentials]
  for d in a:data
    let cmd += ["--data-urlencode", d]
  endfor
  call add(cmd, a:req)
  return init#OnJobOutput(cmd, a:cb)
endfunction

function! s:ReleaseBuild(branch)
  throw "Does not exactly work... But it's close!"

  if exists('g:JENKINS_TRACKED_BUILD[0]')
    call init#ToClipboard(g:JENKINS_TRACKED_BUILD[0])
    return
  endif

  let git_dir = FugitiveExtractGitDir(g:AIDISTRO)
  let branch = empty(a:branch) ? git#GetBranch(git_dir) : a:branch
  call git#ExecuteOrThrow([git_dir, "push", "origin", branch])
  let url = "https://jenkins.alcatraz.ai/job/aidistro_obsidian_release/buildWithParameters"
  call work#OnJenkinsPost(url, ["branch=" .. branch], function("s:OnBuildTriggered"))
endfunction

function! s:OnBuildTriggered(resp)
  let prefix = "location: "
  let resp = filter(a:resp, 'stridx(v:val, prefix) >= 0')
  if empty(resp)
    return init#Warn("Build information is missing in response!")
  endif
  let location = trim(resp[0][len(prefix):])
  let g:JENKINS_TRACKED_BUILD = [location, "s:PingBuildQueue"]
  call s:PingBuildQueue()
endfunction

function! s:PingBuildQueue(...)
  if !exists("g:JENKINS_TRACKED_BUILD[0]")
    return
  endif
  let req = g:JENKINS_TRACKED_BUILD[0] .. "api/json"
  call work#OnJenkinsResponse(req, function("s:OnQueueItem"))
endfunction

function! s:OnQueueItem(dict)
  if has_key(a:dict, "executable")
    let g:JENKINS_TRACKED_BUILD = [a:dict.executable.url, "s:PingQueuedBuild"]
    call s:PingQueuedBuild()
  elseif has_key(a:dict, "why")
    let g:statusline_dict['jenkins'] = a:dict["why"]
    call timer_start(3000, function("s:PingBuildQueue"))
  else
    " call init#Warn("")
    " call assert_false()
    " unlet g:JENKINS_TRACKED_BUILD
    " let g:statusline_dict['jenkins'] = ''
    " call init#Warn("Dropping build " .. g:JENKINS_TRACKED_BUILD[0])
  endif
endfunction

function! s:PingQueuedBuild(...)
  if !exists("g:JENKINS_TRACKED_BUILD[0]")
    return
  endif
  let req = g:JENKINS_TRACKED_BUILD[0] .. "api/json"
  call work#OnJenkinsResponse(req, function("s:OnBuildStatus"))
endfunction

function! s:OnBuildStatus(dict)
  let building = get(a:dict, "building", v:true)
  let result = get(a:dict, "result", "")
  if !building
    call init#Warn("Build " .. result)
    call qutil#CreateCustomQuickfix([a:dict.url], "Build", function("s:OnBuildFinished"))
    let g:JENKINS_TRACKED_BUILD = []
    let g:statusline_dict['jenkins'] = ''
  else
    " TODO what here?
    " let g:statusline_dict['jenkins'] = a:dict["why"]
    call timer_start(3000, function("s:PingQueuedBuild"))
  endif
endfunction

function! s:OnBuildFinished()
  let url = getline('.')
  call init#ToClipboard(url)
  quit
endfunction

command! -nargs=? -complete=customlist,AidistroCompl Jenkins call s:ReleaseBuild(<q-args>)

" }}}

""""""""""""""""""""""""""""Jira"""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let g:jira_token_file = stdpath('state') .. "/jira_token.txt"
if filereadable(g:jira_token_file)
  let g:jira_token = readfile(g:jira_token_file)[0]
  let today = strftime('%Y-%m-%d')
  if today >=# '2027-05-22'
    call init#Warn("Your jira token has expired!")
  endif
else
  call init#Warn("No jira token set up!")
  let g:jira_token = ""
endif

function! work#OnJiraResponse(query, data, cb)
  let credentials = printf("%s:%s", g:alcatraz_ai_user, g:jira_token)
  let cmd = ["curl", "--silent", "--globoff", "-u", credentials, "--get", "--data-urlencode", a:query]

  let data = ["maxResults=100"] + a:data
  for d in data
    let cmd += ["--data", d]
  endfor

  let url = "https://alcatrazai.atlassian.net/rest/api/3/search/jql"
  call add(cmd, url)
  return init#OnJobOutput(cmd, function("s:DecodeJsonResponse", [a:cb]))
endfunction

function! s:OnAssignedIssues(cb)
  let q = "jql=assignee=currentUser() ORDER BY updated DESC"
  call work#OnJiraResponse(q, ['fields=status,summary'], function("s:OnIssuesResponse", [a:cb]))
endfunction

function! s:OnIssuesResponse(cb, dict)
  let issues = a:dict["issues"]
  let items = map(issues, '#{id: v:val.key, title: v:val.fields.summary, status: v:val.fields.status.name}')
  call function(a:cb)(items)
endfunction

function! s:ShowUnresolved(items)
  let done = ["Won't fix", "Released", "Duplicate", "Tech limitation", "Can't Reproduce", "DONE"]
  let items = filter(a:items, 'index(done, v:val.status) < 0')
  let names = map(items, 'printf("%s [%s]: %s", v:val.id, v:val.status, v:val.title)')
  call qutil#CreateCustomQuickfix(names, "Issues", function("s:OpenUnresolved"))
endfunction

function! s:OpenUnresolved()
  let issue = work#ExtractIssue(getline('.'))
  call work#OpenJira(issue)
endfunction

command! -nargs=0 Issues call s:OnAssignedIssues(function("s:ShowUnresolved"))

" TODO BUILD NUMBER! it is hard coded in the url
" function! s:DownloadArtifact()
"   let credentials = printf("%s:%s", g:alcatraz_ai_user, g:jenkins_token)
"   let req = "https://jenkins.alcatraz.ai/job/aidistro_obsidian_release/256/s3/download/rock-prod-image-rockx-dm-r10.mender"
"   let path = expand("~/Downloads/rock-prod-image-rockx-dm-r10.mender")
"   let cmd = ["curl", "--silent", "-L", "-o", path, "-u", credentials, req]
"   call init#OnJobExit(cmd, function("s:InstallImage", [path]))
" endfunction

" function! s:OnDownloadArtifact(path, code)
"   if a:code != 0 || !filereadable(path)
"     return init#Warn("Downloading artifact failed!")
"   endif
"   call s:InstallImage(a:path)
" endfunction

" command! -nargs=0 Test call s:DownloadArtifact()
" }}}

function! s:OnVimEnter()
  " Install commands for the first time
  call s:OnHostChange()

  if exists("g:JENKINS_TRACKED_BUILD[1]")
    let ResumedHandler = function(g:JENKINS_TRACKED_BUILD[1])
    call ResumedHandler()
  endif
endfunction

augroup Work
  autocmd! VimEnter * ++once call s:OnVimEnter()
augroup END

function! s:ShowShadaVars()
  let shada_vars = filter(copy(g:), 'v:key =~# ''^[A-Z][A-Z_]*$''')
  let text = map(items(shada_vars), 'printf("%s=%s", v:val[0], v:val[1])')
  call init#CustomBottomBuffer('Vars', text)
endfunction

command! -nargs=0 Vars call s:ShowShadaVars()
