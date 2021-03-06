if exists("b:current_syntax")
  finish
endif

syn match NeogitObjectId /^[a-z0-9]\{7} /
syn match NeogitBranch /.*/ contained
syn match NeogitRemote /[a-zA-Z/]/ contained
syn match NeogitDiffAdd /.*/ contained
syn match NeogitDiffDelete /.*/ contained
syn match NeogitStash /stash@{[0-9]*}\ze/
syn match NeogitUnmergedInto /Unmerged into/ contained
syn match NeogitUnpulledFrom /Unpulled from/ contained

let b:sections = ["Untracked files", "Unstaged changes", "Unmerged changes", "Staged changes", "Stashes"]

for section in b:sections
  let id = join(split(section, " "), "")
  execute 'syn match Neogit' . id . ' /^' . section . '/ contained'
  execute 'syn region Neogit' . id . 'Region start=/^' . section . '\ze.*/ end=/./ contains=Neogit' . id
  execute 'hi def link Neogit' . id . ' Function'
endfor

syn region NeogitHeadRegion start=/^Head: \zs.*/ end=/$/ contains=NeogitBranch
syn region NeogitPushRegion start=/^Push: \zs.*/ end=/$/ contains=NeogitRemote
syn region NeogitUnmergedIntoRegion start=/^Unmerged into .*/ end=/$/ contains=NeogitRemote,NeogitUnmergedInto
syn region NeogitUnpulledFromRegion start=/^Unpulled from .*/ end=/$/ contains=NeogitRemote,NeogitUnpulledFrom
syn region NeogitDiffAddRegion start=/^+.*$/ end=/$/ contains=NeogitDiffAdd
syn region NeogitDiffDeleteRegion start=/^-.*$/ end=/$/ contains=NeogitDiffDelete

hi def link NeogitBranch Macro
hi def link NeogitRemote SpecialChar
hi def link NeogitObjectId Comment

hi def link NeogitDiffAdd DiffAdd
hi def link NeogitDiffDelete DiffDelete

hi def link NeogitUnmergedInto Function
hi def link NeogitUnpulledFrom Function

hi def link NeogitStash Comment

"TODO: find a better way to do this
hi Folded guibg=None guifg=None
