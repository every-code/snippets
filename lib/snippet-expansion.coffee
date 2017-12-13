{CompositeDisposable, Range, Point} = require 'atom'
Insertion = require './insertion'

module.exports =
class SnippetExpansion
  settingTabStop: false
  ignoringBufferChanges: false

  constructor: (@snippet, @editor, @cursor, @snippets) ->
    @subscriptions = new CompositeDisposable
    @tabStopMarkers = []
    @selections = [@cursor.selection]

    startPosition = @cursor.selection.getBufferRange().start
    {body, tabStopList} = @snippet
    tabStops = tabStopList.toArray();
    if @snippet.lineCount > 1 and indent = @editor.lineTextForBufferRow(startPosition.row).match(/^\s*/)[0]
      # Add proper leading indentation to the snippet
      body = body.replace(/\n/g, '\n' + indent)

      # Make new tab stops that are aware of the indentation level.
      tabStops = tabStops.map (tabStop) ->
        tabStop.copyWithIndent(indent)

    @editor.transact =>
      newRange = @editor.transact =>
        @cursor.selection.insertText(body, autoIndent: false)
      if @snippet.tabStopList.length > 0
        @subscriptions.add @editor.onDidChange (event) => @editorChanged(event, tabStops)
        @subscriptions.add @cursor.onDidChangePosition (event) => @cursorMoved(event)
        @subscriptions.add @cursor.onDidDestroy => @cursorDestroyed()
        @placeTabStopMarkers(startPosition, tabStops)
        @snippets.addExpansion(@editor, this)
        @editor.normalizeTabsInBufferRange(newRange)

  cursorMoved: ({oldBufferPosition, newBufferPosition, textChanged}) ->
    return if @settingTabStop or textChanged
    @destroy() unless @tabStopMarkers.some (groups) ->
      groups.some (item) ->
        item.marker.getBufferRange().containsPoint(newBufferPosition)

  cursorDestroyed: -> @destroy() unless @settingTabStop

  editorChanged: (event, tabStops) ->
    return if @ignoringBufferChanges
    @editor.transact => @applyTransformations()

  applyTransformations: (initial = false) ->
    items = [@tabStopMarkers[@tabStopIndex]...]
    return if items.length == 0

    @ignoringBufferChanges = true

    primary = items.shift()
    primaryMarker = primary.marker
    primaryRange = primaryMarker.getBufferRange()
    inputText = @editor.getTextInBufferRange(primaryRange)

    for item, index in items
      {marker, insertion} = item
      range = marker.getBufferRange()
      # On the initial expansion pass, we only want to manipulate text on tab
      # stops that have transforms. Otherwise `${1:foo}` will apply its
      # placeholder text to `$1`.
      continue if initial and !insertion.isTransformation()
      outputText = insertion.transform(inputText)
      @editor.setTextInBufferRange(range, outputText)
      # Make sure the range for this marker gets updated to reflect the extent
      # of the new contents.
      newRange = new Range(
        range.start,
        range.start.traverse(new Point(0, outputText.length))
      )
      marker.setBufferRange(newRange)

    @ignoringBufferChanges = false

  placeTabStopMarkers: (startPosition, tabStops) ->
    for tabStop, index in tabStops
      {insertions} = tabStop
      @tabStopMarkers[index] ?= []
      for insertion in insertions
        {range} = insertion
        {start, end} = range
        marker = @editor.markBufferRange([
          startPosition.traverse(start),
          startPosition.traverse(end)
        ], {
          exclusive: false
        })
        @tabStopMarkers[index].push({
          index: index,
          marker: marker,
          insertion: insertion
        })
    unless @setTabStopIndex(0)
      @destroy()
      return
    @applyTransformations(true)

  goToNextTabStop: ->
    nextIndex = @tabStopIndex + 1
    if nextIndex <= @tabStopMarkers.length
      if @setTabStopIndex(nextIndex)
        true
      else
        @goToNextTabStop()
    else
      @destroy()
      false

  goToPreviousTabStop: ->
    @setTabStopIndex(@tabStopIndex - 1) if @tabStopIndex > 0

  setTabStopIndex: (@tabStopIndex) ->
    console.log 'setTabStopIndex:', @tabStopIndex
    @settingTabStop = true
    markerSelected = false
    # @selectionDisposable.dispose() if @selectionDisposable
    # @selectionDisposable = new CompositeDisposable
    # @subscriptions.add @selectionDisposable

    items = @tabStopMarkers[@tabStopIndex]
    return false unless items

    ranges = []
    for item in items
      {marker, insertion} = item
      continue unless marker.isValid()
      continue if insertion.isTransformation()
      ranges.push(marker.getBufferRange())

    if ranges.length > 0
      selection.destroy() for selection in @selections[1...]
      @selections = @selections[...ranges.length]
      for range, i in ranges
        if @selections[i]
          @selections[i].setBufferRange(range)
        else
          newSelection = @editor.addSelectionForBufferRange(ranges[0])
          @subscriptions.add newSelection.cursor.onDidChangePosition (event) => @cursorMoved(event)
          @subscriptions.add newSelection.cursor.onDidDestroy => @cursorDestroyed()
          @selections.push newSelection

      markerSelected = true

    @settingTabStop = false
    markerSelected

  destroy: ->
    @subscriptions.dispose()
    for items in @tabStopMarkers
      item.marker.destroy() for item in items
    @tabStopMarkers = []
    @snippets.clearExpansions(@editor)

  restore: (@editor) ->
    @snippets.addExpansion(@editor, this)
