" vim: set sw=2 ts=2 sts=2 foldmethod=marker:

""""""""""""""""""""""""""""Commit tag"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! s:BranchIssueNumber()
  let branch = init#BranchName()
  return matchstr(branch, 'SW-[0-9]\{4\}')
endfunction

function! s:OnNewCommit()
  setlocal spell
  setlocal tw=90
  setlocal cc=91
  let issue = s:BranchIssueNumber()
  if empty(getline(1)) && !empty(issue)
    call setline(1, issue .. ': ')
    startinsert!
  endif
endfunction

autocmd FileType gitcommit call s:OnNewCommit()
"}}}

""""""""""""""""""""""""""""Building"""""""""""""""""""""""""""" {{{
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function s:ObsidianMake(...)
  let repo = FugitiveWorkTree()
  if empty(repo)
    echo "Not inside repo"
    return
  endif
  let repo = split(FugitiveWorkTree(), "/")[-1]
  let obsidian_repos = ["obsidian-video", "libalcatraz", "mpp", "camera_engine_rkaiq", "badge-and-face"]
  if index(obsidian_repos, repo) < 0
    echo "Unsupported repo: " . repo
    return
  endif

  let common_flags = join([
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.4.0/", g:sdk_dir),
        \ printf("-isystem %s/sysroots/armv8a-aisys-linux/usr/include/c++/11.4.0/aarch64-aisys-linux", g:sdk_dir),
        \ "-O0 -ggdb -U_FORTIFY_SOURCE"])
  let cxxflags = "export CXXFLAGS=" . string(common_flags)
  let cflags = "export CFLAGS=" . string(common_flags)

  let dir = printf("cd %s", FugitiveWorkTree())
  let env = printf("source %s/environment-setup-armv8a-aisys-linux", g:sdk_dir)

  if repo == 'camera_engine_rkaiq'
    let cmake = printf("cmake -S. -B%s -DCMAKE_BUILD_TYPE=%s", g:build_type, g:build_type)
    let cmake .= printf(" -DIQ_PARSER_V2_EXTRA_CFLAGS='-I%s/sysroots/armv8a-aisys-linux/usr/include/rockchip-uapi;", g:sdk_dir)
    let cmake .= printf("-I%s/sysroots/armv8a-aisys-linux/usr/include'", g:sdk_dir)
    let cmake .= " -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DISP_HW_VERSION='-DISP_HW_V30' -DARCH='aarch64' -DRKAIQ_TARGET_SOC='rk3588'"
  else
    let cmake = printf("cmake -B %s -S . -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_BUILD_TYPE=%s", g:build_type, g:build_type)
  endif
  let build = printf("cmake --build %s -j 10", g:build_type)

  let cmds = [dir, env, cxxflags, cflags, cmake, build]
  let command = ["/bin/bash", "-c", join(cmds, ';')]

  let bang = get(a:, 1, "")
  return Make(command, bang)
endfunction

function! s:ResolveEnvFile()
  let fname = expand("%:f")
  let resolved = ""
  if stridx(fname, "include/alcatraz") >= 0
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
  endif

  if filereadable(resolved)
    let view = winsaveview()
    exe "edit " . resolved
    call winrestview(view)
  else
    echo "Sorry, I'm buggy, Update me! Resolved to: " . resolved
  endif
endfunction

command! -nargs=0 -bang Make call <SID>ObsidianMake("<bang>")
command! -nargs=0 Clean call system("rm -rf " . FugitiveFind(g:build_type))
nnoremap <silent> <leader>env :call <SID>ResolveEnvFile()<CR>
"}}}

""""""""""""""""""""""""""""Host commands"""""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! RemoteExeCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let pat = "*" . a:ArgLead . "*"
  let find = "find /var/tmp -name " . shellescape(pat) . " -type f -executable"
  return systemlist(["ssh", "-o", "ConnectTimeout=1", g:host, find])
endfunction

function! SshfsCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif

  let dirname = empty(a:ArgLead) ? '/' : fnamemodify(a:ArgLead, ':h')
  let remote_dirs = systemlist(["ssh", g:host, "find " . dirname . " -maxdepth 1 -type d"])
  let remote_dirs = map(remote_dirs, 'v:val . "/"')
  call filter(remote_dirs, 'v:val != "//"')
  let remote_files = systemlist(["ssh", g:host, "find " . dirname . " -maxdepth 1 -type f"])
  let total = remote_dirs + remote_files
  return filter(total, 'stridx(v:val, a:ArgLead) == 0')
endfunction

function! s:RemoteSync(arg, ...)
  function! OnStdout(id, data, event)
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

  function! OnExit(id, code, event)
    if a:code == 0
      echom "Synced!"
    else
      echom "Sync failed!"
    endif
    let g:statusline_dict['sync'] = ''
  endfunction

  let dir = a:arg
  if !isdirectory(dir) && !filereadable(dir)
    echo "Not found: " . dir
    return
  endif
  " Remove leading / or rsync will be naughty
  if dir[-1:-1] == '/'
    let dir = dir[0:-2]
  endif
  const remote_dir = g:host . ":/var/tmp/"

  let cmd = ["rsync", "-rlt"]

  const fast_sync = v:true
  if fast_sync
    " Include all directories
    call add(cmd, '--include=*/')
    " Include all executables
    let exes = systemlist(["find", dir, "-type", "f", "-executable", "-printf", "%P\n"])
    for exe in exes
      " throw exe
      call add(cmd, '--include=' . exe)
    endfor
    " Exclude rest. XXX: ORDER OF FLAGS MATTERS!
    call add(cmd, '--exclude=*')
  endif

  let bang = get(a:000, 0, "")
  if empty(bang)
    call extend(cmd, ["--info=progress2", dir, remote_dir])
    return jobstart(cmd, #{on_stdout: funcref("OnStdout"), on_exit: funcref("OnExit")})
  else
    bot new
    call extend(cmd, ["--info=all4", dir, remote_dir])
    let id = termopen(cmd, #{on_exit: funcref("OnExit")})
    call cursor("$", 1)
    return id
  endif
endfunction

function! s:Resync()
  let dir = FugitiveFind(g:build_type)
  exe printf("autocmd! User MakeSuccessful ++once call s:RemoteSync('%s')", dir)
  call s:ObsidianMake()
endfunction

function s:MakeNiceApp(exe)
  let dst = "/tmp/" .. fnamemodify(a:exe, ":t")
  let cmd = printf("cp --preserve=timestamps %s %s && setcap cap_sys_nice+ep %s", a:exe, dst, dst)
  let msg = systemlist(["ssh", g:host, cmd])
  if v:shell_error
    call init#ShowErrors(msg)
    throw "Failed to prepare " . a:exe
  endif
  return dst
endfunction

function! s:PrepareApp(exe)
  if a:exe =~ "mock_video$"
    let nice_exe = s:MakeNiceApp(a:exe)
    return #{exe: nice_exe, user: "rock-video"}
  elseif a:exe =~ "obsidian-video$"
    let nice_exe = s:MakeNiceApp(a:exe)
    return #{exe: nice_exe, user: "rock-video"}
  elseif a:exe =~ "rtsp-server$"
    let nice_exe = s:MakeNiceApp(a:exe)
    let nice_exe ..= " --noauth"
    return #{exe: nice_exe, user: "rtsp-server"}
  elseif a:exe =~ "focus-tool$"
    let nice_exe = s:MakeNiceApp(a:exe)
    return #{exe: nice_exe, user: "rock-video"}
  elseif a:exe =~ "badge_and_face$"
    let nice_exe = s:MakeNiceApp(a:exe)
    return #{exe: nice_exe, user: "badge_and_face"}
  elseif !empty(a:exe)
    return #{exe: a:exe}
  else
    return #{headless: v:true}
  endif
endfunction

function! work#DebugApp(exe, run)
  let opts = s:PrepareApp(a:exe)
  if a:run
    let opts['br'] = init#GetDebugLoc()
  endif
  let opts['ssh'] = g:host
  " Part of main init.vim
  call init#Debug(opts)
endfunction

function! s:StartMaster()
  if exists('s:master_job_id')
    if jobstop(s:master_job_id)
      call jobwait([s:master_job_id])
    endif
  endif
  let cmd = ["ssh", "-o", "ConnectTimeout=1", "-N", "-M", g:host]
  let s:master_job_id = jobstart(cmd, #{})
  if s:master_job_id <= 0
    echoerr "Failed to start SSH master!"
  endif
endfunction

function! ChangeHostNoMessage(host, check)
  let host = empty(a:host) ? g:default_host : a:host
  if a:check
    call system(["ssh", "-o", "ConnectTimeout=1", host, "exit"])
    if v:shell_error != 0
      echo "Failed to connect to host " . host
      return
    endif
  endif
  let g:host = host
  exe printf("command! -nargs=? -complete=customlist,RemoteExeCompl Start call init#TryCall('work#DebugApp', <q-args>, v:false)")
  exe printf("command! -nargs=? -complete=customlist,RemoteExeCompl Run call init#TryCall('work#DebugApp', <q-args>, v:true)")
  exe printf("command! -nargs=1 -complete=customlist,HistoryCompl Attach call init#RemoteAttach('%s', <q-args>)", g:host)
  exe printf("command! -nargs=1 -complete=customlist,SshfsCompl Sshfs call init#Sshfs('%s', <q-args>)", g:host)
  exe printf("command! -nargs=0 Scp call init#Scp('%s')", g:host)
  call s:StartMaster()
endfunction

function! ChangeHost(host, check)
  call ChangeHostNoMessage(a:host, a:check)
  if s:master_job_id > 0
    echo "SSH Master running..."
  endif
endfunction

function! ChangeHostCompl(ArgLead, CmdLine, CursorPos)
  if a:CursorPos < len(a:CmdLine)
    return []
  endif
  let lines = readfile("/home/" .. $USER .. "/.ssh/config")
  let matches = matchstrlist(lines, 'Host \(\i\+\)$', #{submatches: v:true})
  let hosts = map(matches, "v:val.submatches[0]")
  return filter(hosts, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! work#ToClipboardApp(app)
  let opts = s:PrepareApp(a:app)
  let cmd = printf("sudo -u %s %s", opts['user'], opts['exe'])
  let @+ = cmd
  echom printf("Copied to clipboard: '%s'.", cmd)
endfunction

command! -nargs=? -complete=customlist,ChangeHostCompl Host call ChangeHost(<q-args>, v:true)

nnoremap <silent> <leader>re <cmd>call <SID>Resync()<CR>
nnoremap <silent> <leader>rv <cmd>call init#TryCall('work#ToClipboardApp', "/var/tmp/Debug/application/obsidian-video")<CR>
nnoremap <silent> <leader>rf <cmd>call init#TryCall('work#ToClipboardApp', "/var/tmp/Debug/application/focus-tool")<CR>
nnoremap <silent> <leader>rs <cmd>call init#TryCall('work#ToClipboardApp', "/var/tmp/Debug/application/rtsp-server")<CR>
nnoremap <silent> <leader>rb <cmd>call init#TryCall('work#ToClipboardApp', "/var/tmp/Debug/bin/badge_and_face")<CR>
"}}}

""""""""""""""""""""""""""""Utility functions"""""""""""""""""""""""""""" {{{
function s:Do(cmd, ...)
  let Partial = function("s:" .. a:cmd, a:000)
  call Partial()
endfunction

function! DoCompl(ArgLead, CmdLine, CursorPos)
  let nargs = len(split(a:CmdLine))
  if a:CursorPos < len(a:CmdLine) || nargs > 2
    return []
  endif
  let cmds = ["StopServices", "DropClients", "UpdateDocker", "RunDocker",
        \ "InstallSdk", "InstallMender", "FakeSdk", "HostDebugSyms"]
  return filter(cmds, "stridx(v:val, a:ArgLead) >= 0")
endfunction

function! s:StopServices()
  let stop_list = [
        \ "rtsp-server-noauth",
        \ "rtsp-server.socket",
        \ "rtsp-server.service",
        \ "obsidian-video",
        \ "badge-and-face",
        \ "qrcode-scanner"
        \ ]
  let cmds = []
  for service in stop_list
    let cmd = "systemctl stop " . service
    call add(cmds, cmd)
  endfor

  let msg = systemlist(["ssh", g:host, join(cmds, ";")])
  if v:shell_error
    bot new
    setlocal buftype=nofile
    call setline(1, msg[0])
    call append(1, msg[1:])
    throw "Failed to stop services"
  endif
  echo "Stopped."
endfunction

function! s:DropClients()
  sp ~/obsidian-video
  Source fd_transmitter
  if search("DropTimeoutClients") == 0
    echo "Failed to find drop call site"
    return
  endif
endfunction

function! s:UpdateDocker()
  sp ~/aidistro/bashrc
  call search('^p="\i*"')
  call setline('.', printf('p="%s"', g:sdk))
  call search('^host="\i*"')
  call setline('.', printf('host="%s"', g:host))
  write
  enew
  lcd ~/aidistro/repo
  1,1G! --paginate pull origin master
  set nomodified
endfunction

function! s:RunDocker()
  sp
  enew
  lcd ~/aidistro
  let cmds = ["sudo docker-compose build ubuntu22", "sudo docker-compose run ubuntu22"]
  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:InstallSdk()
  let sdks = systemlist(["find", "/home/" .. $USER .. "/aidistro/cache/tmp/deploy/sdk/", "-regex", printf(".*%s.*dev.sh", g:sdk)])
  if empty(sdks)
    echo "No sdk found"
    return
  endif
  let most_recent_file = sdks[0]
  for file in sdks[1:]
    if getftime(file) > getftime(most_recent_file)
      let most_recent_file = file
    endif
  endfor
  split
  enew
  call termopen(printf("sudo %s -d /opt/aisys/obsidian_%s/ -y", most_recent_file, g:sdk))
  startinsert
endfunction

function! s:InstallMender()
  let images = systemlist(["find", "/home/" .. $USER .. "/aidistro/cache/tmp/deploy/images/", "-regex", printf(".*%s.*mender", g:sdk)])
  if empty(images)
    echo "No image found"
    return
  endif
  let most_recent_image = images[0]
  for image in images[1:]
    if getftime(image) > getftime(most_recent_image)
      let most_recent_image = image
    endif
  endfor
  split
  enew
  let cmds = []
  call add(cmds, printf("scp %s %s:/tmp/image.mender", most_recent_image, g:host))
  call add(cmds, printf("ssh %s mender install /tmp/image.mender", g:host))
  call add(cmds, "echo Reboot required!")

  call termopen(join(cmds, ";"))
  startinsert
endfunction

function! s:FakeSdk()
  let cmds = []
  call add(cmds, printf("sudo cp -v ~/libalcatraz/Debug/alcatraz/libalcatraz.so* %s/sysroots/armv8a-aisys-linux/usr/lib/", g:sdk_dir))
  call add(cmds, printf("sudo cp -v -r ~/libalcatraz/include/alcatraz/* %s/sysroots/armv8a-aisys-linux/usr/include/alcatraz/", g:sdk_dir))
  call add(cmds, printf("scp ~/libalcatraz/Debug/alcatraz/libalcatraz.so.* %s:/usr/lib", g:host))
  if !empty(cmds)
    split
    enew
    call termopen(join(cmds, ";"))
    startinsert
  endif
endfunction

function! s:HostDebugSyms(pat)
  let dir = g:sdk_dir .. "/sysroots/armv8a-aisys-linux/usr/lib/.debug"
  let pat = ".*" .. a:pat .. ".*"
  let files = systemlist(["find", dir, "-regex", pat])
  let bytes = 0
  for file in files
    let bytes += getfsize(file)
  endfor
  let max_bytes = 100 * 1000 * 1000
  if bytes > max_bytes
    echo "Too much debugging symbols selected."
    return
  endif

  let remote_dir = g:host . ":/usr/lib/.debug"
  let msg = systemlist(printf("rsync -lt %s %s", join(files), remote_dir))
  if v:shell_error
    call init#ShowErrors(msg)
  else
    botr split
    enew
    let so = map(files, "fnamemodify(v:val, ':t')")
    call setline(1, so)
    set nomodified
    echo "Debug symbols installed!"
  endif
endfunction

command -nargs=+ -complete=customlist,DoCompl Do call s:Do(<f-args>)
"}}}

""""""""""""""""""""""""""""AI distro"""""""""""""""""""""""""" {{{
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
function! work#FetchAI()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  echo "Fetching from origin..."

  e ~/aidistro/repo
  call init#WorkTreeCleanOrThrow()

  let dict = FugitiveExecute(["checkout", "master"])
  let dict = FugitiveExecute(["pull", "origin", "master"])
  if dict['exit_status'] != 0
    throw "Failed to pull aidistro"
  endif

  for [repo, branch, _] in targets
    " Find new hash
    exe "e " .. repo
    let dict = FugitiveExecute(["fetch", "origin", branch])
    if dict['exit_status'] != 0
      throw "Fetch in " .. repo .. " failed"
    endif
  endfor

  echo "Fetching completed!"
  for [repo, branch, bitbake] in targets
    " Find new hash
    exe "e " .. repo
    let new_hash = init#HashOrThrow("origin/" .. branch)
    " Find old hash
    let id = QuickFind("~/aidistro/repo", "-regex", ".*" .. bitbake)
    call jobwait([id])
    if search("SRCREV") == 0
      throw "Failed to find bitbake file"
    endif
    normal 0f"vi"y
    let old_hash = @0
    " Compare and exchange
    if new_hash != old_hash
      exe printf("substitute /%s/%s/", old_hash, new_hash)
      write
    endif
  endfor
  " Display changes
  e ~/aidistro/repo
  G
  exe "normal \<C-w>w"
  quit
endfunction

function! work#CommitAI()
  let targets = [
        \ ["~/libalcatraz", "master", "libalcatraz_git.bb"],
        \ ["~/obsidian-video", "main", "obsidian-video_git.bb"],
        \ ["~/badge-and-face", "obsidian-master", "badge-and-face-obsidian_git.bb"]]

  e ~/aidistro/repo
  let dict = FugitiveExecute(["diff", "--name-only", "--cached"])
  if dict['exit_status'] != 0 || dict['stdout'][0] == ''
    throw "Cannot determine what changed in aidistro."
  endif
  let staged = dict['stdout']
  for [repo, branch, bitbake] in reverse(targets)
    let staged_bitbake = filter(copy(staged), 'stridx(v:val, bitbake) >= 0')
    if empty(staged_bitbake)
      continue
    endif
    " Get commit message. This is needed to create the branch and the commit
    exe "e " .. repo
    let dict = FugitiveExecute(["log", "-1", "--format=%B", "origin/" .. branch])
    if dict['exit_status'] != 0
      throw "Cannot determine commit message for " .. repo
    endif
    let msg = dict['stdout'][0]
    let issue = matchstr(msg, 'SW-[0-9]\{4\}')
    " Create branch
    e ~/aidistro/repo
    let ai_branch = "stef/" .. issue .. "/ai"
    let dict = FugitiveExecute(["checkout", "-b", ai_branch])
    if dict['exit_status'] != 0
      throw "Failed to create branch " .. ai_branch
    endif
    let ai_msg = repo[2:] .. ": " .. msg
    let dict = FugitiveExecute(["commit", "-m", ai_msg])
    if dict['exit_status'] != 0
      throw printf("Failed to commit changes with message '%s'", ai_msg)
    endif
    " Success
    exe "Gdrop " .. ai_branch
    return
  endfor
  throw "Unexpected failure, fixme!"
endfunction

function! work#PushAI()
  e ~/aidistro/repo
  let dict = FugitiveExecute(["push", "origin", "HEAD"])
  if dict['exit_status'] != 0
    throw "Failed to push branch to origin"
  endif
  let @+ = "https://gitlab.com/Rainbe/Firmware/aidistro/-/merge_requests"
  echo "URL copied to clipboard!"
endfunction

function! work#FinishAI()
  e ~/aidistro/repo
  let branch = init#CheckedBranchOrThrow()
  let dict = FugitiveExecute(["checkout", "master"])
  if dict['exit_status'] != 0
    throw "Failed to checkout master"
  endif
  " Not the end of the world if this fails.
  call FugitiveExecute(["reset", "--hard"])
  let dict = FugitiveExecute(["pull", "origin", "master"])
  if dict['exit_status'] != 0
    throw "Failed to pull new changes"
  endif
  let dict = FugitiveExecute(["branch", "-D", branch])
  if dict['exit_status'] != 0
    throw "Failed to delete newly created branch"
  endif
  echo "Finished!"
endfunction

function! s:AI(qarg)
  if a:qarg == "0"
    call init#TryCall("work#FetchAI")
  elseif a:qarg == "1"
    call init#TryCall("work#CommitAI")
  elseif a:qarg == "2"
    call init#TryCall("work#PushAI")
  elseif a:qarg == "3"
    call init#TryCall("work#FinishAI")
  else
    echo "WTF you on about?"
  endif
endfunction

command! -nargs=1 AI call s:AI(<q-args>)
cabbr Ai AI
" }}}
