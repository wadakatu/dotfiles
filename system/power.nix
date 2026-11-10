{ ... }: {
  # 充電器につないでいる間は、アイドルでスリープさせない。バッテリー駆動時は macOS の既定のまま。
  # launchd の StartInterval で動かす処理はスリープ中に発火しないので、夜間に自動処理を動かすマシンだけに入れる
  # (flake.nix の mkDarwin に extraModules で渡す)。
  #
  # nix-darwin の power.sleep.computer は使わない。実装が `systemsetup -setComputerSleep` で、電源の種類を
  # 選べず、バッテリー駆動時もスリープしなくなるため (pin 済みソース rev 56c666e の modules/power/sleep.nix)。
  # 代わりに pmset を直接呼ぶ。pmset(1): `-c` は charger (wall power)、
  # `sleep` は "system sleep timer (value in minutes, or 0 to disable)"。
  # postActivation は nix-darwin がユーザー向けに空で用意している hook で、switch 時に root で実行される
  # (同 rev の modules/system/activation-scripts.nix)。
  #
  # 知っておくこと:
  # - pmset の設定は OS 側に残る。このモジュールを外しても戻らないので、戻すときは `sudo pmset -c sleep 1`。
  # - 止めるのはアイドルスリープだけ。蓋を閉じたときのスリープと、バッテリー駆動時のスリープは変わらない。
  system.activationScripts.postActivation.text = ''
    echo "power: disabling idle sleep on charger..." >&2
    /usr/bin/pmset -c sleep 0
  '';
}
