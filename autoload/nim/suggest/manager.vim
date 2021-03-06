" nimsuggest management routines
"
" Copyright 2019 Leorize <leorize+oss@disroot.org>
"
" Licensed under the terms of the ISC license,
" see the file "license.txt" included within this distribution.

" type NimsuggestConfig = {
"   'nimsuggest': '/path/to/nimsuggest' (or any binary in PATH)
"   'extraArgs': [] (a list of extra arguments for nimsuggest, will be passed
"                    after the default arguments ['--autobind',
"                    '--address:localhost'])
"   'autofind': v:true (attempt to find the actual project file)
" }
"
" exception 'suggest-manager-':
"   'compat': regarding compatibility with nimsuggest
"   'running': regarding an instance 'running' state
"   'ready': regarding an instance 'ready' state
"   'exec': regarding execution of an external program
"   'file': regarding files
"   'connect': regarding connection

" Poor man's typing. This is a method table for all SuggestInstance
let s:SuggestInstance = {}

" Checks if the given instance is running.
function! s:SuggestInstance.isRunning() abort
  return self.job != 0
endfunction

" Checks if the given instance can receive connections.
function! s:SuggestInstance.isReady() abort
  return self.job != 0 && self.port != 0
endfunction

" Starts the instance, can also be used to restart a dead instance.
function! s:SuggestInstance.start() abort
  if self.isRunning()
    throw 'suggest-manager-running: instance is already running'
  endif
  let self.port = 0
  let self.job = 0
  let job = jobstart([self.cmd] + self.args + [self.file], self)
  if job == 0
    throw 'suggest-manager-exec: unable to start nimsuggest'
  elseif job == -1
    throw 'suggest-manager-exec: nimsuggest (' . self.cmd . ') cannot be executed'
  endif
  let self.job = job
endfunction

" A thin wrapper over jobstop() for stopping an instance. Does nothing if the
" instance is not running.
function! s:SuggestInstance.stop() abort dict
  if self.isRunning()
    call jobstop(self.job)
  endif
endfunction

" Messages the instance asynchronously.
"
" This function is a convenience wrapper around the editor's tcp messaging
" functions that connect to and send the specified message to the instance. It
" does not attempt to provide an abstraction layer over the editor's
" facilities, so mandatory arguments will be interpreted differently
" between editors.
"
" It might take a while for the instance to become ready. If immediate result
" is wanted, pass v:true as the third argument.
"
" data: See ':h chansend' on neovim
" opts: See ':h sockconnect' on neovim
" mustReady (optional): Throw if instance is not ready
"
" If the instance died before message can be sent, `on_data` will be called with
" on_data(0, [''], 'data').
"
" Will throw if instance is not running.
function! s:SuggestInstance.message(data, opts, ...) abort dict
  let mustReady = a:0 >= 1 ? a:1 : v:false
  let scoped = {}
  function scoped.message(nothrow) abort closure
    try
      let channel = sockconnect('tcp', 'localhost:' . self.port, a:opts)
    catch
      if a:nothrow
        call a:opts.on_data(0, [''], 'data')
        return
      else
        throw 'suggest-manager-connect: unable to connect to nimsuggest'
      endif
    endtry
    call chansend(channel, a:data)
  endfunction

  function scoped.onReady(event) abort closure
    if a:event == 'ready'
      call scoped.message(v:true)
    else
      call a:opts.on_data(0, [''], 'data')
    endif
  endfunction
  let scoped.message = function(scoped.message, self)
  let scoped.onReady = function(scoped.onReady, self)

  if !self.isReady()
    if !mustReady
      call self.addCallback(scoped.onReady)
    elseif !self.isRunning()
      throw 'suggest-manager-running: instance is not running'
    else
      throw 'suggest-manager-ready: instance is not ready'
    endif
  else
    call scoped.message(v:false)
  endif
endfunction

" Set a callback to be called when the instance is ready. The callback will
" also be called if the instance died.
"
" callback: function(event)
"   event => 'ready': Instance is ready
"   event => 'exit': Instance didn't finish initializing and exited
function! s:SuggestInstance.addCallback(callback) abort dict
  if !self.isRunning()
    throw 'suggest-manager-running: instance is not running'
  elseif self.isReady()
    call a:callback('ready')
  else
    call add(self.oneshots, a:callback)
  endif
endfunction

" Get the project directory responsible by the instance
function! s:SuggestInstance.project() abort dict
  return fnamemodify(self.file, ':h')
endfunction

" Given a path, check if it's covered by the current nimsuggest instance
function! s:SuggestInstance.contains(path) abort
  let path = isdirectory(a:path) ? fnamemodify(a:path, ':p') : fnamemodify(a:path, ':p:h')
  return path =~ '\V\^' . escape(self.project(), '\')
endfunction

" Send a query to the instance.
"
" command: A command string for nimsuggest (ie. 'highlight', 'sug', 'def', etc.)
" opts: {
"   'on_data': function(reply) [dict]: Will be called for every reply from
"                                      nimsuggest. Each reply will be a List
"                                      splitted by '\t' and passed to the
"                                      callback. An empty list means end of
"                                      response. The callback will also be
"                                      called with an empty list if nimsuggest
"                                      died before it was ready.
"   'buffer' (optional): The number of the buffer containing the file used for
"                        the query. If not exist will be populated with the
"                        current buffer number.
"   'pos' (optional): [lnum, col]: The cursor position, if not available will
"                                  not be passed to nimsuggest.
" }
" mustReady (optional): Throw if instance is not ready.
"
" It might take a while before the instance can be ready. If an immediate
" answer is required, pass v:true as the third parameter.

" Will throw if instance is not running.
function! s:SuggestInstance.query(command, opts, ...) abort
  let mustReady = a:0 >= 1 ? a:1 : v:false
  if !has_key(a:opts, 'buffer')
    let a:opts['buffer'] = bufnr('')
  endif

  let invalidChars = '"\|\n\|\r'
  let filename = bufname(a:opts.buffer)
  if filename =~ invalidChars
    throw 'suggest-manager-file: unsupported character in path to file'
  endif
  let dirtyFile = ''
  let fileQuery = '"' . filename . '"'
  if getbufvar(a:opts.buffer, '&modified')
    let dirtyFile = tempname()
    " shouldn't happen, but doesn't hurt to check
    if dirtyFile =~ invalidChars
      throw 'suggest-manager-file-internal: unsupported character in path to dirty file'
    endif
    let fileQuery .= ';' . dirtyFile
    call writefile(getbufline(a:opts.buffer, 1, '$'), dirtyFile, 'S')
  endif
  if has_key(a:opts, 'pos')
    let fileQuery .= ':' . a:opts.pos[0] . ':' . (a:opts.pos[1] - 1)
  endif

  let opts = {}
  function opts.cleanup() abort closure
    if !empty(dirtyFile)
      call delete(dirtyFile)
    endif
    call a:opts.on_data([])
  endfunction
  function opts.on_data(chan, line, stream) abort closure
    if empty(a:line)
      call chanclose(a:chan)
      call self.cleanup()
    else
      call a:opts.on_data(split(trim(a:line), '\t', v:true))
    endif
  endfunction

  let opts.on_data = nim#suggest#utils#BufferNewline(opts.on_data)
  try
    call self.message([a:command . ' ' . fileQuery, ''], opts, mustReady)
  catch
    call opts.cleanup()
    throw v:exception
  endtry
endfunction

function! s:instanceHandler(chan, line, stream) abort dict
  let scoped = {}
  function scoped.doOneshot(event) abort
    if !empty(self.oneshots)
      for F in self.oneshots
        call F(a:event)
      endfor
      let self.oneshots = []
    endif
  endfunction
  let scoped.doOneshot = function(scoped.doOneshot, self)

  if a:stream == 'stdout' && self.port == 0
    let self.port = str2nr(a:line)
    call self.cb('ready', '')
    call scoped.doOneshot('ready')
    return
  elseif a:stream == 'stderr' && self.port == 0 && a:line =~ '^cannot find file:'
    call self.cb('error', 'suggest-manager-file: file cannot be opened by nimsuggest')
    return
  elseif a:stream == 'exit'
    let self.job = 0
    let self.port = 0
    call scoped.doOneshot('exit')
  endif
  call self.cb(a:stream, a:line)
endfunction

function! s:findProjectMain(path) abort
  let current = a:path
  let prev = current
  let pkg = fnamemodify(a:path, ':t')
  let candidates = []

  let nimblepkg = ''
  while v:true
    " arcane magic to make sure that the path seperator appear at the end
    let esccur = fnameescape(fnamemodify(current, ':p'))
    let escprv = fnameescape(fnamemodify(prev, ':p'))
    let configs = []
    for ext in ['*.nims', '*.cfg', '*.nimcfg', '*.nimble']
      call extend(configs, glob(esccur . ext, v:true, v:true))
    endfor

    for f in configs
      if f == 'config.nims'
        continue
      elseif fnamemodify(f, ':e') == 'nimble'
        if empty(nimblepkg)
          let nimblepkg = fnamemodify(f, ':t:r')
        else
          " more than one nimble file found, don't trust the result
          return ''
        endif
      endif
      let candidate = fnameescape(fnamemodify(f, ':t:r') . '.nim')
      for i in current != a:path && !empty(nimblepkg) ? [esccur, escprv] : [esccur]
        call extend(candidates, glob(i . candidate, v:true, v:true))
      endfor
    endfor

    for f in candidates
      let fname = fnamemodify(f, ':t')
      if stridx(fname, !empty(nimblepkg) ? nimblepkg : pkg) != -1
        return f
      endif
    endfor
    if !empty(candidates)
      return candidates[0]
    endif
    let prev = current
    let current = fnamemodify(current, ':h')
    if prev == current
      return ''
    endif
  endwhile
endfunction

" Creates a new nimsuggest instance
" config: NimsuggestConfig
" file: /path/to/file, can be relative to the cwd, must be available on disk
" callback: function(event, message) dict:
"   event == 'ready'  => nimsuggest has been initialized and connections can
"                        now be established
"   event == 'error'  => message will be a String following the
"                        'suggest-manager' exeception format described above.
"                        After an error event callback, an exit callback
"                        should soon follow
"   event == 'stdout' => message will be the latest line emitted by
"            'stderr'    nimsuggest to stdout/stderr (note: processed lines
"                        will not be relayed)
"   event == 'exit'   => message will be the exit code of nimsuggest
"
" See the result variable below for the returned Dict. It's not advised to
" edit the dict without using the functions in this file.
function! nim#suggest#manager#NewInstance(config, file, callback) abort
  let help = system([a:config.nimsuggest, '--help'])
  if v:shell_error == -1
    throw 'suggest-manager-exec: nimsuggest (' . a:config.nimsuggest . ') cannot be executed'
  elseif help !~ '--autobind'
    throw 'suggest-manager-compat: only nimsuggest >= 0.20.0 is supported'
  endif

  let result = {'job': 0,
      \         'port': 0,
      \         'file': fnamemodify(a:file, ':p'),
      \         'cmd': a:config.nimsuggest,
      \         'args': ['--autobind', '--address:localhost'] + a:config.extraArgs,
      \         'on_stdout': nim#suggest#utils#BufferNewline(function('s:instanceHandler')),
      \         'on_stderr': nim#suggest#utils#BufferNewline(function('s:instanceHandler')),
      \         'on_exit': nim#suggest#utils#BufferNewline(function('s:instanceHandler')),
      \         'cb': a:callback,
      \         'oneshots': []}
  call extend(result, s:SuggestInstance)
  if !has_key(a:config, 'autofind') || a:config.autofind
    let projectFile = s:findProjectMain(result.project())
    if !empty(projectFile)
      let result.file = projectFile
    endif
  endif

  call result.start()
  return result
endfunction
