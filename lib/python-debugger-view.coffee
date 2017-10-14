{Point, Disposable, CompositeDisposable} = require "atom"
{$, $$, View, TextEditorView} = require "atom-space-pen-views"
Breakpoint = require "./breakpoint"
BreakpointStore = require "./breakpoint-store"

spawn = require("child_process").spawn
path = require "path"
fs = require "fs"

module.exports =
class PythonDebuggerView extends View
  debuggedFileName: null
  debuggedFileArgs: []
  backendDebuggerPath: null
  backendDebuggerName: "atom_pdb.py"
  flagActionStarted: false
  flagVarsNeedUpdate: false
  flagCallstackNeedsUpdate: false
  # 0 - normal output, 1 - print variables, 2 - print call stack
  currentState: 0
  varScrollTop: 0
  callStackScrollTop: 0

  getCurrentFilePath: ->
    editor = atom.workspace.getActivePaneItem()
    file = editor?.buffer.file
    return file?.path

  getDebuggerPath: ->
    pkgs = atom.packages.getPackageDirPaths()[0]
    debuggerPath = path.join(pkgs, "python-debugger", "resources")
    return debuggerPath

  @content: ->
    @div class: "pythonDebuggerView", =>
      @subview "argsEntryView", new TextEditorView
        mini: true,
        placeholderText: "> Enter input arguments here"
      @subview "commandEntryView", new TextEditorView
        mini: true,
        placeholderText: "> Enter debugger commands here"
      @div class: "btn-toolbar", =>
          @div class: "btn-group", =>
              @button outlet: "breakpointBtn", click: "toggleBreak", class: "btn", =>
                @span "break point"
          @div class: "btn-group", =>
              @button outlet: "runBtn", click: "runApp", class: "btn", =>
                @span "run"
              @button outlet: "stopBtn", click: "stopApp", class: "btn", =>
                @span "stop"
          @div class: "btn-group", =>
              @button outlet: "stepOverBtn", click: "stepOverBtnPressed", class: "btn", =>
                @span "next"
              @button outlet: "stepInBtn", click: "stepInBtnPressed", class: "btn", =>
                @span "step"
              @button outlet: "returnBtn", click: "returnBtnPressed", class: "btn", =>
                @span "return"
              @button outlet: "continueBtn", click: "continueBtnPressed", class: "btn", =>
                @span "continue"
          @div class: "btn-group", =>
              @button outlet: "upBtn", click: "upBtnPressed", class: "btn", =>
                @span "up"
              @button outlet: "downBtn", click: "downBtnPressed", class: "btn", =>
                @span "down"
          @div class: "btn-group", =>
              @button outlet: "clearBtn", click: "clearOutput", class: "btn", =>
                @span "clear"
          @input class : "input-checkbox", type: "checkbox", id: "ck_input", outlet: "showInput", click: "toggleInput"
          @label class : "label", for: "ck_input", =>
            @span "Input"
          @input class : "input-checkbox", type: "checkbox", id: "ck_vars", outlet: "showVars", click: "toggleVars"
          @label class : "label", for: "ck_vars", =>
            @span "Variables"
          @input class : "input-checkbox", type: "checkbox", id: "ck_callstack", outlet: "showCallstack", click: "toggleCallstack"
          @label class : "label", for: "ck_callstack", =>
            @span "Call stack"
      @div class: "block", outlet: "bottomPane", =>
        @div class: "inline-block panel", id: "outputPane", outlet: "outputPane", =>
          @pre class: "command-output", outlet: "output"
        @div class: "inline-block panel", id: "variablesPane", outlet: "variablesPane", =>
          @pre class: "command-output", outlet: "variables"
        @div class: "inline-block panel", id: "callstackPane", outlet: "callstackPane", =>
          @pre class: "command-output", outlet: "callstack"

  toggleInput: ->
    if @backendDebugger
      @argsEntryView.hide()
      if @showInput.prop('checked')
        @commandEntryView.show()
      else
        @commandEntryView.hide()
    else
      if @showInput.prop('checked')
        @argsEntryView.show()
      else
        @argsEntryView.hide()
      @commandEntryView.hide()

  toggleVars: ->
    @togglePanes()

  toggleCallstack: ->
    @togglePanes()

  togglePanes: ->
    n = 1
    if @showVars.prop('checked')
      @variablesPane.show()
      n = n+1
    else
      @variablesPane.hide()
    if @showCallstack.prop('checked')
      @callstackPane.show()
      n = n+1
    else
      @callstackPane.hide()
    width = ''+(100/n)+'%'
    @outputPane.css('width', width)
    if @showVars.prop('checked')
      @variablesPane.css('width', width)
    if @showCallstack.prop('checked')
      @callstackPane.css('width', width)
    # the following statements are used to update the information in the variables/callstack
    @setFlags()
    @backendDebugger?.stdin.write("print 'display option changed.'\n")

  toggleBreak: ->
    editor = atom.workspace.getActiveTextEditor()
    filename = editor.getTitle()
    lineNumber = editor.getCursorBufferPosition().row + 1
    breakpoint = new Breakpoint(filename, lineNumber)
    cmd = @breakpointStore.toggle(breakpoint)
    if @backendDebugger
      @backendDebugger.stdin.write(cmd + " " + @getCurrentFilePath() + ":" + lineNumber + "\n")
    @output.empty()
    for breakpoint in @breakpointStore.breakpoints
      @output.append(breakpoint.toCommand() + "\n")

  stepOverBtnPressed: ->
    @setFlags()
    @backendDebugger?.stdin.write("n\n")

  stepInBtnPressed: ->
    @setFlags()
    @backendDebugger?.stdin.write("s\n")

  continueBtnPressed: ->
    @setFlags()
    @backendDebugger?.stdin.write("c\n")

  returnBtnPressed: ->
    @setFlags()
    @backendDebugger?.stdin.write("r\n")

  upBtnPressed: ->
    @setFlags()
    @backendDebugger?.stdin.write("up\n")

  downBtnPressed: ->
    @setFlags()
    @backendDebugger?.stdin.write("down\n")

  printVars: ->
    @variables.empty()
    @backendDebugger?.stdin.write("print ('@{variables_start}')\n")
    @backendDebugger?.stdin.write("for (__k, __v) in [(__k, __v) for __k, __v in globals().items() if not __k.startswith('__')]: print __k, '=', __v\n")
    @backendDebugger?.stdin.write("print '-------------'\n")
    @backendDebugger?.stdin.write("for (__k, __v) in [(__k, __v) for __k, __v in locals().items() if __k != 'self' and not __k.startswith('__')]: print __k, '=', __v\n")
    @backendDebugger?.stdin.write("for (__k, __v) in [(__k, __v) for __k, __v in (self.__dict__ if 'self' in locals().keys() else {}).items()]: print 'self.{0}'.format(__k), '=', __v\n")
    @backendDebugger?.stdin.write("print ('@{variables_end}')\n")

  printCallstack: ->
    @callstack.empty()
    @backendDebugger?.stdin.write("print ('@{callstack_start}')\n")
    @backendDebugger?.stdin.write("bt\n")
    @backendDebugger?.stdin.write("print ('@{callstack_end}')\n")

  setFlags: ->
    @flagActionStarted = true
    if @showVars.prop('checked')
     @varScrollTop = @variables.prop('scrollTop')
     @flagVarsNeedUpdate = true
    if @showCallstack.prop('checked')
      @callStackScrollTop = @callstack.prop('scrollTop')
      @flagCallstackNeedsUpdate = true

  workspacePath: ->
    editor = atom.workspace.getActiveTextEditor()
    activePath = editor.getPath()
    relative = atom.project.relativizePath(activePath)
    pathToWorkspace = relative[0] || (path.dirname(activePath) if activePath?)
    pathToWorkspace

  runApp: ->
    @stopApp() if @backendDebugger
    @debuggedFileArgs = @getInputArguments()
    console.log @debuggedFileArgs
    @debuggedFileName = @getCurrentFilePath()
    if @pathsNotSet()
      @askForPaths()
      return
    @setFlags()
    @runBackendDebugger()
    @toggleInput()

  highlightLineInEditor: (fileName, lineNumber) ->
    if lineNumber && fileName
      lineNumber = parseInt(lineNumber)
      editor = atom.workspace.getActiveTextEditor()
      if fileName.toLowerCase() == editor.getPath().toLowerCase()
        position = Point(lineNumber-1, 0)
        editor.setCursorBufferPosition(position)
        editor.unfoldBufferRow(lineNumber)
        editor.scrollToBufferPosition(position)
      else
        options = {initialLine: lineNumber-1, initialColumn:0}
        atom.workspace.open(fileName, options) if fs.existsSync(fileName)
        # TODO: add decoration to current line?

  processNormalOutput: (data_str) ->

    lineNumber = null
    fileName = null

    # print the action_end string
    if @flagActionStarted
        @backendDebugger?.stdin.write("print ('@{action_end}')\n")
        @flagActionStarted = false

    # detect predefined flag strings
    isActionEnd = data_str.includes('@{action_end}')
    isVarsStart = data_str.includes('@{variables_start}')
    isCallstackStart = data_str.includes('@{callstack_start}')

    # variables print started
    if isVarsStart
        @currentState = 1
        @processVariables(data_str)
        return

    # call stack print started
    if isCallstackStart
        @currentState = 2
        @processCallstack(data_str)
        return

    # handle normal output
    [data_str, tail] = data_str.split("line:: ")
    if tail
      [lineNumber, tail] = tail.split("\n")
      data_str = data_str + tail if tail

    [data_str, tail] = data_str.split("file:: ")
    if tail
      [fileName, tail] = tail.split("\n")
      data_str = data_str + tail if tail
      fileName = fileName.trim() if fileName
      fileName = null if fileName == "<string>"

    # highlight the current line
    if lineNumber && fileName
      @highlightLineInEditor(fileName, lineNumber)

    # print the output
    @addOutput(data_str.trim().replace('@{action_end}', ''))

    # if action end, trigger the follow up actions
    if isActionEnd
      if @flagVarsNeedUpdate
        @printVars()
        @flagVarsNeedUpdate = false
      else
        if @flagCallstackNeedsUpdate
          @printCallstack()
          @flagCallstackNeedsUpdate = false

  processVariables: (data_str) ->
    isVarsEnd = data_str.includes('@{variables_end}')
    for line in data_str.split '\n'
      if ! line.includes("@{variable")
        @variables.append(@createOutputNode(line))
        @variables.append('\n')
    if isVarsEnd
      @variables.prop('scrollTop', @varScrollTop)
      @currentState = 0
      if @flagCallstackNeedsUpdate
        @printCallstack()
        @flagCallstackNeedsUpdate = false

  processCallstack: (data_str) ->
    lineNumber = null
    fileName = null
    isCallstackEnd = data_str.includes('@{callstack_end}')
    m = /[^-]> (.*[.]py)[(]([0-9]*)[)].*/.exec(data_str)
    if m
      [fileName, lineNumber] = [m[1], m[2]]
      callstack_pre = @callstack
      `
      re = /[\n](>*)[ \t]*(.*[.]py)[(]([0-9]*)[)]([^\n]*)[\n]([^\n]*)/gi;
      while ((match = re.exec(data_str)))
      {
        if (match[5].includes('exec cmd in globals, locals')) continue;
        if (match[1].includes('>'))
          item = "<b><u>"+match[5].replace("->", "")+"</u></b>";
        else
          item = match[5].replace("->", "");
        callstack_pre.append(item);
        callstack_pre.append('\n');
      }
      `
    if lineNumber && fileName
      @highlightLineInEditor(fileName, lineNumber)
    if isCallstackEnd
      @currentState = 0
      @callstack.prop('scrollTop', @callStackScrollTop)

  # Extract the file name and line number output by the debugger.
  processDebuggerOutput: (data) ->
    data_str = data.toString().trim()
    if @currentState == 1
      @processVariables(data_str)
    else if @currentState == 2
      @processCallstack(data_str)
    else
      @processNormalOutput(data_str)

  runBackendDebugger: ->
    args = [path.join(@backendDebuggerPath, @backendDebuggerName)]
    args.push(@debuggedFileName)
    args.push(arg) for arg in @debuggedFileArgs
    python = atom.config.get "python-debugger.pythonExecutable"
    console.log("python-debugger: using", python)
    @backendDebugger = spawn python, args

    for breakpoint in @breakpointStore.breakpoints
      @backendDebugger.stdin.write(breakpoint.toCommand() + "\n")

    # Move to first breakpoint if there are any.
    if @breakpointStore.breakpoints.length > 0
      @backendDebugger.stdin.write("c\n")

    @backendDebugger.stdout.on "data", (data) =>
      @processDebuggerOutput(data)
    @backendDebugger.stderr.on "data", (data) =>
      @processDebuggerOutput(data)
    @backendDebugger.on "exit", (code) =>
      @addOutput("debugger exits with code: " + code.toString().trim()) if code?

  stopApp: ->
    @backendDebugger?.stdin.write("\nexit()\n")
    @backendDebugger = null
    console.log "debugger stopped"
    @toggleInput()

  clearOutput: ->
    @output.empty()

  createOutputNode: (text) ->
    node = $("<span />").text(text)
    parent = $("<span />").append(node)

  addOutput: (data) ->
    atBottom = @atBottomOfOutput()
    node = @createOutputNode(data)
    @output.append(node)
    @output.append("\n")
    if atBottom
      @scrollToBottomOfOutput()

  pathsNotSet: ->
    !@debuggedFileName

  askForPaths: ->
    @addOutput("To use a different entry point, set file to debug using e=fileName")

  initialize: (breakpointStore) ->
    @breakpointStore = breakpointStore
    @debuggedFileName = @getCurrentFilePath()
    @backendDebuggerPath = @getDebuggerPath()
    @toggleInput()
    @togglePanes()
    @addOutput("Welcome to Python Debugger for Atom!")
    @addOutput("The file being debugged is: " + @debuggedFileName)
    @askForPaths()
    @subscriptions = atom.commands.add @element,
      "core:confirm": (event) =>
        if @parseAndSetPaths()
          @clearInputText()
        else
          @confirmBackendDebuggerCommand()
        event.stopPropagation()
      "core:cancel": (event) =>
        @cancelBackendDebuggerCommand()
        event.stopPropagation()

  parseAndSetPaths:() ->
    command = @getCommand()
    return false if !command
    if /e=(.*)/.test command
      match = /e=(.*)/.exec command
      @debuggedFileName = match[1]
      @addOutput("The file being debugged is: " + @debuggedFileName)
      return true
    return false

  stringIsBlank: (str) ->
    !str or /^\s*$/.test str

  escapeString: (str) ->
    !str or str.replace(/[\\"']/g, '\\$&').replace(/\u0000/g, '\\0')

  getInputArguments: ->
    args = @argsEntryView.getModel().getText()
    return if !@stringIsBlank(args) then args.split(" ") else []

  getCommand: ->
    command = @commandEntryView.getModel().getText()
    command if !@stringIsBlank(command)

  cancelBackendDebuggerCommand: ->
    @commandEntryView.getModel().setText("")

  confirmBackendDebuggerCommand: ->
    if !@backendDebugger
      @addOutput("Program not running")
      return
    command = @getCommand()
    if command
      @backendDebugger.stdin.write(command + "\n")
      @clearInputText()

  clearInputText: ->
    @commandEntryView.getModel().setText("")

  serialize: ->
    attached: @panel?.isVisible()

  destroy: ->
    @detach()

  toggle: ->
    if @panel?.isVisible()
      @detach()
    else
      @attach()

  atBottomOfOutput: ->
    @output[0].scrollHeight <= @output.scrollTop() + @output.outerHeight()

  scrollToBottomOfOutput: ->
    @output.scrollToBottom()

  attach: ->
    console.log "attached"
    @panel = atom.workspace.addBottomPanel(item: this)
    @panel.show()
    @scrollToBottomOfOutput()

  detach: ->
    console.log "detached"
    @panel.destroy()
    @panel = null
