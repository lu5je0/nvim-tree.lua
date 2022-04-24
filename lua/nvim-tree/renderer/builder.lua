local utils = require "nvim-tree.utils"

local git = require "nvim-tree.renderer.components.git"
local pad = require "nvim-tree.renderer.components.padding"
local icons = require "nvim-tree.renderer.components.icons"

-- TODO(refactor): the builder abstraction is not perfect yet. We shouldn't leak data in components.
-- Components should return only and icon / highlight group pair at most.
-- The code was mostly moved from renderer/init.lua and rearranged, so it's still under construction.

local Builder = {}
Builder.__index = Builder

function Builder.new(root_cwd)
  return setmetatable({
    index = 0,
    depth = nil,
    highlights = {},
    lines = {},
    markers = {},
    root_cwd = root_cwd,
  }, Builder)
end

function Builder:configure_initial_depth(show_arrows)
  self.depth = show_arrows and 2 or 0
  return self
end

function Builder:configure_root_modifier(root_folder_modifier)
  self.root_folder_modifier = root_folder_modifier or ":~"
  return self
end

function Builder:configure_trailing_slash(with_trailing)
  self.trailing_slash = with_trailing and "/" or ""
  return self
end

function Builder:configure_special_map(special_map)
  self.special_map = special_map
  return self
end

function Builder:configure_picture_map(picture_map)
  self.picture_map = picture_map
  return self
end

function Builder:configure_opened_file_highlighting(level)
  if level == 1 then
    self.open_file_highlight = "icon"
  elseif level == 2 then
    self.open_file_highlight = "name"
  elseif level == 3 then
    self.open_file_highlight = "all"
  end

  return self
end

function Builder:_insert_highlight(group, start, end_)
  table.insert(self.highlights, { group, self.index, start, end_ or -1 })
end

function Builder:_insert_line(line)
  table.insert(self.lines, line)
end

local function get_folder_name(node)
  local name = node.name
  local next = node.group_next
  while next do
    name = name .. "/" .. next.name
    next = next.group_next
  end
  return name
end

function Builder:_build_folder(node, padding, git_hl)
  local offset = string.len(padding)

  local name = get_folder_name(node)
  local has_children = #node.nodes ~= 0 or node.has_children
  local icon = icons.get_folder_icon(node.open, node.link_to ~= nil, has_children)
  local git_icon = git.get_icons(node, self.index, offset, #icon, self.highlights) or ""

  local folder_hl = "NvimTreeFolderName"
  if self.special_map[node.absolute_path] then
    folder_hl = "NvimTreeSpecialFolderName"
  elseif node.open then
    folder_hl = "NvimTreeOpenedFolderName"
  elseif not has_children then
    folder_hl = "NvimTreeEmptyFolderName"
  end

  icons.set_folder_hl(
    self.index,
    offset,
    #icon + #git_icon,
    #name,
    "NvimTreeFolderIcon",
    folder_hl,
    self.highlights,
    self.open_file_highlight
  )
  if git_hl then
    icons.set_folder_hl(
      self.index,
      offset,
      #icon + #git_icon,
      #name,
      git_hl,
      git_hl,
      self.highlights,
      self.open_file_highlight
    )
  end
  self:_insert_line(padding .. icon .. git_icon .. name .. self.trailing_slash)
end

-- TODO: missing git icon for symlinks
function Builder:_build_symlink(node, padding, git_highlight)
  local icon = icons.i.symlink
  local arrow = icons.i.symlink_arrow

  local link_highlight = git_highlight or "NvimTreeSymlink"

  local line = padding .. icon .. node.name .. arrow .. node.link_to
  self:_insert_highlight(link_highlight, string.len(padding), string.len(line))
  self:_insert_line(line)
end

function Builder:_build_file_icons(node, offset)
  if self.special_map[node.absolute_path] or self.special_map[node.name] then
    local git_icons = git.get_icons(node, self.index, offset, 0, self.highlights)
    self:_insert_highlight("NvimTreeSpecialFile", offset + #git_icons)
    return icons.i.special, git_icons
  else
    local icon = icons.get_file_icon(node.name, node.extension, self.index, offset, self.highlights)
    return icon, git.get_icons(node, self.index, offset, #icon, self.highlights)
  end
end

function Builder:_highlight_opened_files(node, offset, icon, git_icons)
  local from = offset
  local to = offset

  if self.open_file_highlight == "icon" then
    to = from + #icon
  elseif self.open_file_highlight == "name" then
    from = offset + #icon + #git_icons
    to = from + #node.name
  elseif self.open_file_highlight == "all" then
    to = -1
  end

  self:_insert_highlight("NvimTreeOpenedFile", from, to)
end

function Builder:_build_file(node, padding, git_highlight)
  local offset = string.len(padding)

  local icon, git_icons = self:_build_file_icons(node, offset)

  self:_insert_line(padding .. icon .. git_icons .. node.name)
  local col_start = offset + #icon + #git_icons

  if node.executable then
    self:_insert_highlight("NvimTreeExecFile", col_start)
  elseif self.picture_map[node.extension] then
    self:_insert_highlight("NvimTreeImageFile", col_start)
  end

  local should_highlight_opened_files = self.open_file_highlight and vim.fn.bufloaded(node.absolute_path) > 0
  if should_highlight_opened_files then
    self:_highlight_opened_files(node, offset, icon, git_icons)
  end

  if git_highlight then
    self:_insert_highlight(git_highlight, col_start)
  end
end

function Builder:build(tree)
  for idx, node in ipairs(tree.nodes) do
    local padding = pad.get_padding(self.depth, idx, tree, node, self.markers)

    if self.depth > 0 then
      self:_insert_highlight("NvimTreeIndentMarker", 0, string.len(padding))
    end

    local git_highlight = git.get_highlight(node)

    local is_folder = node.nodes ~= nil
    local is_symlink = node.link_to ~= nil

    if is_folder then
      self:_build_folder(node, padding, git_highlight)
    elseif is_symlink then
      self:_build_symlink(node, padding, git_highlight)
    else
      self:_build_file(node, padding, git_highlight)
    end
    self.index = self.index + 1

    if node.open then
      self.depth = self.depth + 2
      self:build(node)
      self.depth = self.depth - 2
    end
  end

  return self
end

local function format_root_name(root_cwd, modifier)
  local base_root = utils.path_remove_trailing(vim.fn.fnamemodify(root_cwd, modifier))
  return utils.path_join { base_root, ".." }
end

function Builder:build_header(show_header)
  if show_header then
    local root_name = format_root_name(self.root_cwd, self.root_folder_modifier)
    self:_insert_line(root_name)
    self:_insert_highlight("NvimTreeRootFolder", 0, string.len(root_name))
    self.index = 1
  end

  return self
end

function Builder:unwrap()
  return self.lines, self.highlights
end

return Builder
