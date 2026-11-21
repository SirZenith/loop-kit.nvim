if exists("b:current_syntax")
  finish
endif

syntax match loopkitId /#\d\+/
syntax match loopkitTag /\[[^\]]*\]$/
syntax match loopkitHeader /^[A-Z][A-Za-z ]*(\d\+)$/

syntax match loopkitDoing /^\s*◐.*$/ contains=loopkitId,loopkitTag
syntax match loopkitPending /^\s*○.*$/ contains=loopkitId,loopkitTag
syntax match loopkitDone /^\s*●.*$/ contains=loopkitId,loopkitTag
syntax match loopkitBlocked /^\s*✕.*$/ contains=loopkitId,loopkitTag

highlight default link loopkitId Identifier
highlight default link loopkitTag Type
highlight default link loopkitHeader Title
highlight default link loopkitDoing LoopKitDoing
highlight default link loopkitPending LoopKitPending
highlight default link loopkitDone LoopKitDone
highlight default link loopkitBlocked LoopKitBlocked

let b:current_syntax = "loopkit"
