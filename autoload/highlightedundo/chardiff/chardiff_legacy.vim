let s:save_cpo = &cpoptions
set cpoptions&vim

function! s:Diff(before, after, ...) abort
  if a:before ==# a:after
    return []
  endif
  let limit = get(a:000, 0, 255)
  if a:before[:limit] ==# a:after[:limit]
    " There is a difference after `limit` bytes.
    return [[[1, strlen(a:before)], [1, strlen(a:after)]]]
  endif
  let beforelen = strlen(a:before)
  let afterlen = strlen(a:after)
  let chunklen = 3
  if min([beforelen, afterlen]) <= chunklen
    return s:compare_short(a:before, a:after)
  endif
  return s:compare(a:before, a:after, limit, chunklen)
endfunction


function! s:Similarity(before, after) abort
  if a:before ==# a:after
    return 1.0
  endif
  let beforelen = strlen(a:before)
  let afterlen = strlen(a:after)
  let chunklen = 3
  let forward_match_p = s:count_coincidence(a:before, a:after, 0, 0)
  let i = forward_match_p
  let j = forward_match_p
  let [_, _, chunk_match_p] = s:chunk_match(a:before, a:after, chunklen, i, j)
  return 1.0*(forward_match_p + chunk_match_p)/min([beforelen, afterlen])
endfunction


function! s:compare_short(str1, str2) abort
  if strlen(a:str1) <= strlen(a:str2)
    return s:compare_short_impl(a:str1, a:str2)
  endif
  return map(s:compare_short_impl(a:str2, a:str1), 'reverse(v:val)')
endfunction


function! s:compare_short_impl(short, long) abort
  let shortexpr = s:to_expr(a:short)
  let i = match(a:long, shortexpr)
  let shortlen = strlen(a:short)
  let longlen = strlen(a:long)
  if i < 0
    " abc, abde
    return [[[1, shortlen], [1, longlen]]]
  endif

  if i == 0
    " abc, abcv
    return [[[shortlen + 1, 0], [shortlen + 1, longlen - shortlen]]]
  elseif i == longlen - shortlen
    " abc, uabc
    return [[[1, 0], [1, longlen - shortlen]]]
  endif
  " abc, uabcv
  return [
  \ [[1, 0], [1, i]],
  \ [[shortlen + 1, 0], [i + shortlen + 1, longlen - shortlen - i]],
  \ ]
endfunction


function! s:compare(before, after, limit, chunklen) abort
  let before = a:before[: a:limit]
  let after = a:after[: a:limit]
  " NOTE: beforelen != strchars(a:before) and
  "       afterlen != strchars(a:after) in this func
  let beforelen = strlen(before)
  let afterlen = strlen(after)
  let loffset = s:count_coincidence(before, after, 0, 0)
  let i = loffset
  let j = loffset
  if i == beforelen
    " abc, abcvvv
    let original_after_len = strlen(a:after)
    return [[[loffset + 1, 0], [loffset + 1, original_after_len - loffset]]]
  elseif j == afterlen
    " abcvvv, abc
    let original_before_len = strlen(a:before)
    return [[[loffset + 1, original_before_len - loffset], [loffset + 1, 0]]]
  endif

  let roffset = s:count_coincidence(before, after, 0, 0, 1)
  let roffset = min([roffset, beforelen - loffset, afterlen - loffset])
  let imax = beforelen - roffset
  let jmax = afterlen - roffset
  let difflist = []
  if i == imax
    " abcdef, abcvvvdef
    call add(difflist, [[loffset + 1, 0], [loffset + 1, afterlen - loffset - roffset]])
  elseif j == jmax
    " abcvvvdef, abcdef
    call add(difflist, [[loffset + 1, beforelen - loffset - roffset], [loffset + 1, 0]])
  else
    let d = s:compare_impl(before[:imax - 1], after[:jmax - 1], a:chunklen, i, j, imax, jmax)
    call extend(difflist, d)
  endif

  let before_rest = a:before[a:limit + 1 :]
  let after_rest = a:after[a:limit + 1 :]
  if before_rest ==# '' && after_rest !=# ''
    call add(difflist, [[a:limit + 2, 0], [a:limit + 2, strlen(after_rest)]])
  elseif before_rest !=# '' && after_rest ==# ''
    call add(difflist, [[a:limit + 2, strlen(before_rest)], [a:limit + 2, 0]])
  elseif before_rest !=# '' && after_rest !=# ''
    call add(difflist, [[a:limit + 2, strlen(before_rest)], [a:limit + 2, strlen(after_rest)]])
  endif
  return difflist
endfunction


function! s:compare_impl(before, after, chunklen, i0, j0, imax, jmax) abort
  let i = a:i0
  let j = a:j0
  let loop = 0
  let loopmax = 100
  let result = []
  while loop < loopmax
    let loop += 1
    let [ii, jj, k] = s:chunk_match(a:before, a:after, a:chunklen, i, j)
    if jj < 0
      " No match
      call add(result, [[i + 1, a:imax - i], [j + 1, a:jmax - j]])
      break
    elseif jj == j
      if ii > i
        call add(result, [[i + 1, ii - i], [j + 1, 0]])
      endif
    else
      if ii > i
        call add(result, [[i + 1, ii - i], [j + 1, jj - j]])
      else
        call add(result, [[i + 1, 0], [j + 1, jj - j]])
      endif
    endif
    let i = ii + k
    let j = jj + k
    if i > a:imax - a:chunklen || j > a:jmax - a:chunklen
      let del = [i + 1, max([a:imax - i, 0])]
      let add = [j + 1, max([a:jmax - j, 0])]
      if add[1] > 0 || del[1] > 0
        call add(result, [del, add])
      endif
      break
    endif
  endwhile
  return result
endfunction


function! s:chunk_match(A, B, chunklen, i0, j0) abort
  let Alen = strlen(a:A)
  let Blen = strlen(a:B)
  let i = Alen - a:chunklen - 1
  let j = -1
  if Alen - a:i0 < a:chunklen || Blen - a:j0 < a:chunklen
    return [i, j, 0]
  endif

  let k = 0
  let slip = a:chunklen*3
  for ii in range(a:i0, Alen - a:chunklen)
    let start = ii
    let end = ii + a:chunklen - 1
    let chunk = a:A[start:end]
    let chunkexpr = s:to_expr(chunk)
    let jj = match(a:B, chunkexpr, a:j0)
    if jj >= 0
      let kk = s:count_coincidence(a:A, a:B, ii, jj)
      if kk > k
        let [i, j, k] = [ii, jj, kk]
      endif
      let slip -= 1
    endif
    if slip <= 0
      break
    endif
  endfor
  return [i, j, k]
endfunction


function! s:to_expr(str) abort
  return '\C' . escape(a:str, '~"\.^$[]*')
endfunction


function! s:count_coincidence(A, B, i, j, ...) abort
  let rev = get(a:000, 0, 0)
  let Alen = strlen(a:A)
  let Blen = strlen(a:B)
  let n = min([Alen - a:i, Blen - a:j])
  if n <= 0
    return 0
  endif

  if !rev
    for k in range(n)
      if a:A[a:i + k] !=# a:B[a:j + k]
        return k
      endif
    endfor
  else
    for k in range(n)
      if a:A[Alen - a:i - k - 1] !=# a:B[Blen - a:j - k - 1]
        return k
      endif
    endfor
  endif
  return n
endfunction


let s:chardiff = {}
let s:chardiff.Diff = funcref('s:Diff')
let s:chardiff.Similarity = funcref('s:Similarity')
function! highlightedundo#chardiff#chardiff_legacy#import() abort
  return s:chardiff
endfunction


let &cpoptions = s:save_cpo
unlet s:save_cpo

" vim:set ts=2 sts=2 sw=2:
