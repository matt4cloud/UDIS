export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="dpoggi"

zstyle ':omz:update' mode auto
zstyle ':omz:update' frequency 7

ENABLE_CORRECTION="true"

plugins=(sudo git)

source $ZSH/oh-my-zsh.sh

alias h="history"
alias vim="nvim"
alias ran="ranger"
alias q="exit"

prompt_context(){}
