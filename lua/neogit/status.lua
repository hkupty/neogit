local Buffer = require("neogit.lib.buffer")
local GitCommandHistory = require("neogit.buffers.git_command_history")
local git = require("neogit.lib.git")
local util = require("neogit.lib.util")
local notif = require("neogit.lib.notification")

local refreshing = false
local status = {}
local locations = {}
local status_buffer = nil

local function get_section_idx_for_line(linenr)
  for i, l in pairs(locations) do
    if l.first <= linenr and linenr <= l.last then
      return i
    end
  end
  return nil
end

local function get_location(section_name)
  for _,l in pairs(locations) do
    if l.name == section_name then
      return l
    end
  end
end

local function get_section_for_line(linenr)
  return locations[get_section_idx_for_line(linenr)]
end

local function get_section_item_idx_for_line(linenr)
  local section_idx = get_section_idx_for_line(linenr)
  local section = locations[section_idx]

  for i, item in pairs(status[section.name]) do
    if item.first <= linenr and linenr <= item.last then
      return section_idx, i
    end
  end

  return section_idx, nil
end

local function get_section_item_for_line(linenr)
  local section_idx, item_idx = get_section_item_idx_for_line(linenr)
  local section = locations[section_idx]

  return section, status[section.name][item_idx]
end

local function get_current_section_item()
  return get_section_item_for_line(vim.fn.line("."))
end

local function insert_diff(section, change)
  if change.type == "Deleted" or change.type == "New file" then
    return
  end

  vim.cmd("normal zd")

  if not change.diff_content then
    if section.name == "staged_changes" then
      change.diff_content = git.diff.staged(change.name)
    else
      change.diff_content = git.diff.unstaged(change.name)
    end
  end

  change.diff_open = true
  change.diff_height = #change.diff_content.lines

  for _, c in pairs(status[section.name]) do
    if c.first > change.last then
      c.first = c.first + change.diff_height
      c.last = c.last + change.diff_height
    end
  end

  for _, s in pairs(locations) do
    if s.first > section.last then
      s.first = s.first + change.diff_height
      s.last = s.last + change.diff_height
      for _, c in pairs(status[s.name]) do
        if c.first > change.last then
          c.first = c.first + change.diff_height
          c.last = c.last + change.diff_height
        end
      end
    end
  end

  change.last = change.first + change.diff_height
  section.last = section.last + change.diff_height

  status_buffer:unlock()
  status_buffer:put(change.diff_content.lines, true, false)
  status_buffer:lock()

  for _, hunk in pairs(change.diff_content.hunks) do
    status_buffer:create_fold(change.first + hunk.first, change.first + hunk.last)
  end

  status_buffer:create_fold(change.first, change.last)
end

local function insert_diffs()
  local function insert(name)
    local location = get_location(name)
    for _,c in pairs(status[name]) do
      if not c.diff_open then
        vim.api.nvim_win_set_cursor(0, { c.first, 0 })
        insert_diff(location, c)
      end
    end
  end
  insert("unstaged_changes")
  insert("staged_changes")
end

local function toggle()
  local linenr = vim.fn.line(".")
  local line = vim.fn.getline(linenr)
  local matches = vim.fn.matchlist(line, "^Modified \\(.*\\)")

  if #matches ~= 0 then
    local section, change = get_current_section_item()

    if change.diff_open then
      vim.cmd("normal za")
      return
    end

    insert_diff(section, change)

    vim.cmd("normal zO")
    vim.cmd("norm k")
  else
    vim.cmd("normal za")
  end
end

local function change_to_str(change)
  return string.format("%s %s", change.type, change.name)
end

local function display_status()
  if status_buffer == nil then
    return
  end

  locations = {}

  local line_idx = 3
  local output = {
    "Head: " .. status.branch,
    "Push: " .. status.remote,
    ""
  }

  local function write(str)
    table.insert(output, str)
    line_idx = line_idx + 1
  end

  local function write_section(options)
    local items

    if options.items == nil then
      items = status[options.name]
    else
      items = options.items
    end

    local len = #items

    if len ~= 0 then
      if type(options.title) == "string" then
        write(string.format("%s (%d)", options.title, len))
      else
        write(options.title())
      end

      local location = {
        name = options.name,
        first = line_idx,
        last = 0
      }

      for _, item in pairs(items) do
        local name = item.name

        if options.display then
          name = options.display(item)
        elseif type(item) == "string" then
          name = item
        end

        write(name)

        if type(item) == "table" then
          item.first = line_idx
          item.last = line_idx
        end
      end

      write("")

      location.last = line_idx

      table.insert(locations, location)
    end
  end

  write_section({
    name = "untracked_files",
    title = "Untracked files"
  })
  write_section({
    name = "unstaged_changes",
    title = "Unstaged changes",
    display = change_to_str
  })
  write_section({
    name = "unmerged_changes",
    title = "Unmerged changes",
    display = change_to_str
  })
  write_section({
    name = "staged_changes",
    title = "Staged changes",
    display = change_to_str
  })
  write_section({
    name = "stashes",
    title = "Stashes",
    display = function(stash)
      return "stash@{" .. stash.idx .. "} " .. stash.name
    end
  })
  write_section({
    name = "unpulled",
    title = function()
      return "Unpulled from " .. status.remote .. " (" .. #status.unpulled .. ")"
    end,
  })
  write_section({
    name = "unmerged",
    title = function()
      return "Unmerged into " .. status.remote .. " (" .. #status.unmerged .. ")"
    end,
  })

  status_buffer:set_lines(0, -1, false, output)

  for _,l in pairs(locations) do
    local items = status[l.name]
    if items ~= nil and l.name ~= "stashes" and l.name ~= "unpulled" and l.name ~= "unmerged" then
      for _, i in pairs(items) do
        status_buffer:create_fold(i.first, i.last)
      end
    end
    status_buffer:create_fold(l.first, l.last)
  end
  status_buffer:set_foldlevel(1)
end

function primitive_move_cursor(line)
  for _,l in pairs(locations) do
    if l.first <= line and line <= l.last then
      vim.api.nvim_win_set_cursor(0, { l.first, 0 })
      break
    end
  end
end

--- TODO: rename
--- basically moves the cursor to the next section if the current one has no more items
--@param name of the current section
--@param name of the next section
--@returns whether the function managed to find the next cursor position
function contextually_move_cursor(current, next, item_idx)
  local items = status[current]
  local items_len = #items

  if items_len == 0 then
    local staged_changes = status[next]
    if #staged_changes ~= 0 then
      vim.api.nvim_win_set_cursor(0, { get_location(next).first + 1, 0 })
    end
    return true
  else
    local line = get_location(current).first
    if item_idx > items_len then
      line = line + items_len
    else
      line = line + item_idx
    end
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    return true
  end

  return false
end

local function refresh_status()
  if status_buffer == nil then
    return
  end

  for _,x in pairs(status) do
    if type(x) == "table" then
      for _,i in pairs(x) do
        i.diff_open = false
      end
    end
  end

  local line = vim.fn.line(".")
  local section_idx = get_section_idx_for_line(line)
  local section = locations[section_idx]

  status_buffer:unlock()
  status_buffer:clear()
  display_status()
  status_buffer:lock()

  if section == nil then
    primitive_move_cursor(line)
    return
  end

  local item_idx = line - section.first

  if section.name == "unstaged_changes" then
    if contextually_move_cursor("unstaged_changes", "staged_changes", item_idx) then
      return
    end
  elseif section.name == "staged_changes" then
    if contextually_move_cursor("staged_changes", "unstaged_changes", item_idx) then
      return
    end
  elseif section.name == "untracked_files" then
    if contextually_move_cursor("untracked_files", "staged_changes", item_idx) or
       contextually_move_cursor("untracked_files", "unstaged_changes", item_idx) then
     return
   end
  end
  primitive_move_cursor(line)
end

function load_diffs()
  local unstaged = {}
  local staged = {}
  for _,c in pairs(status.unstaged_changes) do
    if c.type ~= "Deleted" and c.type ~= "New file" and not c.diff_open and not c.diff_content then
      table.insert(unstaged, c.name)
    end
  end
  local unstaged_len = #unstaged
  for _,c in pairs(status.staged_changes) do
    if c.type ~= "Deleted" and c.type ~= "New file" and not c.diff_open and not c.diff_content then
      table.insert(staged, c.name)
    end
  end
  local cmds = {}
  for _, c in pairs(unstaged) do
    table.insert(cmds, "diff " .. c)
  end
  for _, c in pairs(staged) do
    table.insert(cmds, "diff --cached " .. c)
  end
  local results = git.cli.run_batch(cmds)

  for i=1,#results do
    if i <= unstaged_len then
      local name = unstaged[i]
      for _,c in pairs(status.unstaged_changes) do
        if c.name == name then
          c.diff_content = git.diff.parse(results[i])
          break
        end
      end
    else
      local name = staged[i - unstaged_len]
      for _,c in pairs(status.staged_changes) do
        if c.name == name then
          c.diff_content = git.diff.parse(results[i])
          break
        end
      end
    end
  end
end

function __NeogitStatusRefresh(force)
  if refreshing or (status_buffer ~= nil and not force) then
    return
  end
  refreshing = true
  status = git.status.get()
  refresh_status()
  refreshing = false
end

function __NeogitStatusOnClose()
  status_buffer = nil
end

function get_hunk_of_item_for_line(item, line)
  local hunk
  for _,h in pairs(item.diff_content.hunks) do
    if item.first + h.first <= line and line <= item.first + h.last then
      hunk = h
      break
    end
  end
  return hunk
end
function get_current_hunk_of_item(item)
  return get_hunk_of_item_for_line(item, vim.fn.line("."))
end

local function add_change(list, item, diff)
  local change = nil
  for _,c in pairs(list) do
    if c.name == item.name then
      change = c
      break
    end
  end

  if change then
    change.diff_content = diff
  else
    local new_item = vim.deepcopy(item)
    new_item.diff_content = diff
    new_item.diff_open = false
    table.insert(list, new_item)
  end
end

local function remove_change(name, item)
  status[name] = util.filter(status[name], function(i)
    return i.name ~= item.name
  end)
end

local function stage_range(item, section, hunk, from, to)
  git.status.stage_range(
    item.name,
    status_buffer:get_lines(item.first + hunk.first, item.first + hunk.last, false),
    hunk,
    from,
    to
  )
  local unstaged_diff = git.diff.unstaged(item.name)
  local staged_diff = git.diff.staged(item.name)

  if #unstaged_diff.lines == 0 then
    remove_change(section.name, item)
  else
    item.diff_open = false
    item.diff_content = unstaged_diff
  end

  if #staged_diff.lines ~= 0 then
    add_change(status.staged_changes, item, staged_diff)
  end
end
local function unstage_range(item, section, hunk, from, to)
  git.status.unstage_range(
    item.name,
    status_buffer:get_lines(item.first + hunk.first, item.first + hunk.last, false),
    hunk,
    from,
    to
  )
  local unstaged_diff = git.diff.unstaged(item.name)
  local staged_diff = git.diff.staged(item.name)

  if #staged_diff.lines == 0 then
    remove_change(section.name, item)
  else
    item.diff_open = false
    item.diff_content = staged_diff
  end

  if #unstaged_diff.lines ~= 0 then
    if item.type == "new file" then
      table.insert(status.untracked_files, item)
    else
      add_change(status.unstaged_changes, item, unstaged_diff)
    end
  end
end
--- Validates the current selection and acts accordingly
--@return nil
--@return number, number
local function get_selection()
  local first_line = vim.fn.getpos("v")[2]
  local last_line = vim.fn.getpos(".")[2]
  local first_section, first_item = get_section_item_for_line(first_line)
  local last_section, last_item = get_section_item_for_line(last_line)

  if not first_section or
     not first_item or
     not last_section or
     not last_item
  then
    return nil
  end

  local first_hunk = get_hunk_of_item_for_line(first_item, first_line)
  local last_hunk = get_hunk_of_item_for_line(last_item, last_line)

  if not first_hunk or not last_hunk then
    return nil
  end

  if first_section.name ~= last_section.name or
     first_item.name ~= last_item.name or
     first_hunk.first ~= last_hunk.first
  then
    return nil
  end

  first_line = first_line - first_item.first
  last_line = last_line - last_item.first

  -- both hunks are the same anyway so only have to check one
  if first_hunk.first == first_line or
     first_hunk.first == last_line
  then
    return nil
  end

  return first_section, first_item, first_hunk, first_line - first_hunk.first, last_line - first_hunk.first
end

local function stage_selection()
  local section, item, hunk, from, to = get_selection()
  if from == nil then
    return
  end
  stage_range(item, section, hunk, from, to)
  refresh_status()
end

local function unstage_selection()
  local section, item, hunk, from, to = get_selection()
  if from == nil then
    return
  end
  unstage_range(item, section, hunk, from, to)
  refresh_status()
end

local function line_is_hunk(line)
  return not vim.fn.matchlist(line, "^\\(Modified\\|New file\\|Deleted\\|Conflict\\) .*")[1]
end

local function stage()
  local section, item = get_current_section_item()

  if section == nil or (section.name ~= "unstaged_changes" and section.name ~= "untracked_files" and section.name ~= "unmerged_changes") or item == nil then
    return
  end

  local mode = vim.api.nvim_get_mode()

  if mode.mode == "V" then
    stage_selection()
    return
  end

  local on_hunk = line_is_hunk(vim.fn.getline('.'))

  if on_hunk and section.name ~= "untracked_files" then
    local hunk = get_current_hunk_of_item(item)
    stage_range(item, section, hunk, nil, nil)
  else
    git.status.stage(item.name)
    remove_change(section.name, item)
    add_change(status.staged_changes, item, git.diff.staged(item.name))
  end

  refresh_status()
end

local function unstage()
  local section, item = get_current_section_item()

  if section == nil or section.name ~= "staged_changes" or item == nil then
    return
  end

  local mode = vim.api.nvim_get_mode()

  if mode.mode == "V" then
    unstage_selection()
    return
  end

  local on_hunk = line_is_hunk(vim.fn.getline('.'))

  if on_hunk then
    local hunk = get_current_hunk_of_item(item)
    unstage_range(item, section, hunk, nil, nil)
  else
    git.status.unstage(item.name)

    remove_change(section.name, item)

    local change = nil
    if item.type ~= "new file" then
      for _,c in pairs(status.unstaged_changes) do
        if c.name == item.name then
          change = c
          break
        end
      end
    end

    if change then
      change.diff_content = git.diff.unstaged(change.name)
    else
      if item.type == "new file" then
        table.insert(status.untracked_files, item)
      else
        table.insert(status.unstaged_changes, item)
      end
    end
  end
  refresh_status()
end

local function create(kind)
  kind = kind or 'tab'
  if status_buffer then
    status_buffer:focus()
    return
  end

  Buffer.create {
    name = "NeogitStatus",
    filetype = "NeogitStatus",
    kind = kind,
    initialize = function(buffer)
      status_buffer = buffer

      -- checks if the status table is {}
      if next(status) == nil then
        status = git.status.get()
      end

      display_status()

      local mappings = buffer.mmanager.mappings

      mappings["1"] = function()
        vim.cmd("set foldlevel=0")
        vim.cmd("norm zz")
      end
      mappings["2"] = function()
        vim.cmd("set foldlevel=1")
        vim.cmd("norm zz")
      end
      mappings["3"] = function()
        vim.cmd("set foldlevel=1")
        insert_diffs()
        vim.cmd("set foldlevel=2")
        vim.cmd("norm zz")
      end
      mappings["4"] = function()
        vim.cmd("set foldlevel=1")
        insert_diffs()
        vim.cmd("set foldlevel=3")
        vim.cmd("norm zz")
      end
      mappings["tab"] = toggle
      mappings["s"] = { "nv", stage, true }
      mappings["S"] = function()
        for _,c in pairs(status.unstaged_changes) do
          table.insert(status.staged_changes, c)
        end
        status.unstaged_changes = {}
        git.status.stage_modified()
        refresh_status()
      end
      mappings["control-s"] = function()
        for _,c in pairs(status.unstaged_changes) do
          table.insert(status.staged_changes, c)
        end
        for _,c in pairs(status.untracked_files) do
          table.insert(status.staged_changes, c)
        end
        status.unstaged_changes = {}
        status.untracked_files = {}
        git.status.stage_all()
        refresh_status()
      end
      mappings["$"] = function()
        GitCommandHistory:new():show()
      end
      mappings["control-r"] = function() __NeogitStatusRefresh(true) end
      mappings["u"] = { "nv", unstage, true }
      mappings["U"] = function()
        for _,c in pairs(status.staged_changes) do
          if c.type == "new file" then
            table.insert(status.untracked_files, c)
          else
            table.insert(status.unstaged_changes, c)
          end
        end
        status.staged_changes = {}
        git.status.unstage_all()
        refresh_status()
      end
      mappings["c"] = require("neogit.popups.commit").create
      mappings["L"] = require("neogit.popups.log").create
      mappings["P"] = require("neogit.popups.push").create
      mappings["p"] = require("neogit.popups.pull").create
      
      vim.defer_fn(load_diffs, 0)
    end
  }
end

return {
  create = create,
  toggle = toggle,
  get_status = function() return status end
}
