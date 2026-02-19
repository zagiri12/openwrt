# AntiLeaks DNS + IP baseline (Raspberry Pi 4 / bcm27xx-bcm2711)

Этот профиль основан на фактическом снимке конфигурации из `vpn-health-checkFIX_result.txt`:

- `lan -> vpn` уже настроен как единственный forwarding.
- DNS для `dnsmasq` уже задан через `noresolv=1` + список Cloudflare/Google.
- Есть блокировка DNS LAN->WAN (tcp/udp 53).
- OpenVPN (`tun0`) поднимается, но в таблице маршрутов остается `default via eth0`, поэтому нужен явный kill switch на форвардинг LAN->WAN.

## Что добавляет `scripts/vpn_antileak_apply.sh`

1. Закрепляет DNS-апстримы (`1.1.1.1`, `1.0.0.1`, `8.8.8.8`, `8.8.4.4`) одновременно в `network.wan` и `dnsmasq`.
2. Принудительно оставляет только `forwarding lan -> vpn`.
3. Добавляет DNS DNAT-перенаправление с LAN на роутер (порт 53) с явным `dest=lan`, чтобы клиенты не обходили локальный `dnsmasq` и не было предупреждений firewall4 о неуказанном destination.
4. Добавляет rule `KillSwitch-LAN-to-WAN` (`REJECT`) для полного запрета выхода клиентов в интернет через WAN при падении VPN.
5. Отключает `lan.ip6assign` и пытается отключить `wan6` (`proto=none`) только если секция `network.wan6` существует (иначе не падает).
6. Делает выполнение идемпотентным: удаляет старые правила по имени перед повторным созданием и выводит диагностические сообщения.
7. Скрипт устойчив к частично отсутствующим UCI-секциям: не завершается «молча», а пишет WARN и продолжает выполнение.
8. Скрипт не делает полный `network reload` и не выполняет `ifup vpn` (чтобы не провоцировать WAN DHCP-флап), а применяет изменения через `reload` только `dnsmasq` и `firewall`.

## Применение

На роутере:

```sh
sh /root/vpn_antileak_apply.sh
# ожидаемо: строки [vpn-antileak] ...
# финал: либо "Anti-leak baseline applied", либо "Finished with warnings; review log lines above"
```

или через исходники/сборку — встроить скрипт в ваш provisioning.

## Минимальная проверка после применения

```sh
uci show firewall | grep -E 'KillSwitch-LAN-to-WAN|Force-DNS-to-Router|Block-DNS-from-LAN-to-WAN'
uci show dhcp | grep -E 'dnsmasq\[0\]\.noresolv|dnsmasq\[0\]\.server'
uci show network | grep -E 'wan\.peerdns|wan\.dns|wan6\.proto|vpn\.'
ip -4 route
nft list ruleset | grep -E 'KillSwitch-LAN-to-WAN|Force-DNS-to-Router|dport 53'
```


## Если скрипт «ничего не выводит»

Проверьте, что файл действительно содержит текст скрипта и не пустой:

```sh
wc -l /root/myscript_fixed.sh
head -n 5 /root/myscript_fixed.sh
```

Для подробной диагностики запускайте так:

```sh
sh -x /root/myscript_fixed.sh
```



## Совместимость shell на роутере

В скрипте не используется `set -u`, чтобы избежать ошибки вида `set: illegal option -` на некоторых минимальных `/bin/sh`.

Если видите `syntax error: unexpected end of file (expecting "fi")`, проверьте, что файл скопирован полностью (без обрезания при копировании):

```sh
wc -l /root/myscript_fixed.sh
sed -n "1,220p" /root/myscript_fixed.sh
```

## Устранение предупреждения `Section @redirect ... does not specify a destination`

Скрипт теперь явно задаёт `dest=lan` в redirect-правилах DNS, поэтому это предупреждение больше не должно появляться.


## Устранение `awk: Unexpected token` на BusyBox

Очистка старых правил больше не использует `awk`-выражения с расширенным синтаксисом.
Теперь используется POSIX-совместимый `sed` + shell `case`, что работает на BusyBox `ash`/`awk` в OpenWrt.
