PROMPT="wadakatu($(arch)):%~ $(git_super_status)"$'\n'"$ "
function git_prompt() {
  if [ "$(git rev-parse --is-inside-work-tree 2> /dev/null)" = true ]; then
    PROMPT="wadakatu ($(arch)):%2c $(git_super_status)"$'\n'"$ "
  else
    PROMPT="wadakatu ($(arch)):%~ "$'\n'"$ "
  fi
}
precmd() {
  git_prompt
}