# OpenVPN Access Server em LXC no Proxmox VE

Script interativo (whiptail) que cria um contêiner LXC **Debian 13 não
privilegiado** no Proxmox VE e instala o
[OpenVPN Access Server](https://openvpn.net/as-docs/) já configurado.

## Requisitos

- Proxmox VE **8.4 ou mais novo** (o `pct` de versões anteriores recusa Debian 13), arquitetura **amd64**. O pacote
- Executar como `root` no shell do nó.
- Acesso à internet a partir do contêiner (`packages.openvpn.net` e `deb.debian.org`).
- Um IP estático livre na rede da bridge escolhida.

## Uso

```bash
# no shell do nó Proxmox
bash openvpn-as-lxc.sh            # cria de verdade
bash openvpn-as-lxc.sh --dry-run  # faz todas as perguntas e só mostra os comandos
```

O script pergunta:

| Item | Padrão |
|------|--------|
| CT ID | próximo livre (`pvesh get /cluster/nextid`) |
| Hostname | `openvpn-as` |
| Senha root do CT | — (mín. 8) |
| Storage do template / do disco | menu (seleção automática se houver só um) |
| Disco / vCPU / RAM | 8 GiB / 2 / 2048 MiB |
| Bridge | menu com as `vmbr*` |
| VLAN tag | vazio = sem VLAN |
| IP/CIDR e gateway | obrigatórios (IP estático) |
| DNS | o gateway |
| Senha do admin (`openvpn`) | — (mín. 8) |
| Host público | o IP do CT (troque pelo seu DNS/IP público) |
| Porta TCP / UDP do daemon VPN | 443 / 1194 |

Antes de criar, uma tela de resumo pede confirmação.

## O que é criado

- Contêiner com `unprivileged: 1`, `features: nesting=1`, `onboot: 1` e
  `dev0: /dev/net/tun` (passthrough do TUN, nativo do PVE 8.1+).
- No host: `/etc/modules-load.d/tun.conf` com `tun`, para o módulo carregar em
  todo boot. Não é gravado se o `tun` já estiver em `/etc/modules` ou em
  `/etc/modules-load.d/`.
- Repositório oficial `http://packages.openvpn.net/as/debian trixie main`
  com a chave em `/etc/apt/keyrings/as-repository.asc`, e o pacote `openvpn-as`.
- Configuração via `sacli`: `host.name`, `vpn.server.daemon.tcp.port`,
  `vpn.server.daemon.udp.port` e a senha local do usuário `openvpn`.
- **DCO desligado** (`vpn.server.daemon.ovpndco=false`). O Data Channel Offload
  (módulo `ovpn` do kernel), padrão no AS 3.x, precisa de `CAP_NET_ADMIN` no
  namespace do host. Num LXC não privilegiado as chamadas netlink falham
  (`dco_get_peer: Operation not permitted`) e os daemons caem. Sem DCO eles
  usam `/dev/net/tun`.

Ao final aparecem as URLs:

- Admin UI: `https://<IP>:943/admin` (usuário `openvpn`)
- Client UI: `https://<IP>:943/`, também servida na porta TCP da VPN

## Portas para liberar no roteador/firewall

| Porta | Uso |
|-------|-----|
| TCP 443 (ou a escolhida) | VPN via TCP + Client UI |
| UDP 1194 (ou a escolhida) | VPN via UDP |
| TCP 943 | Admin UI — **mantenha interna** se possível |

## Segurança das senhas

As senhas não aparecem no terminal, no log nem na linha de comando do host.
Elas vão num arquivo `0600` enviado com `pct push`, lido pelo instalador e
apagado logo em seguida. A única exceção é o `sacli SetLocalPassword`, que
não aceita a senha por stdin: por um instante ela fica visível ao root
**dentro** do contêiner.

## Logs e erros

- Log completo: `/var/log/openvpn-as-lxc-<CTID>.log` no host.
- Se algo falhar depois da criação do contêiner, o script pergunta se deve
  destruí-lo (`pct destroy --purge`) ou mantê-lo para inspeção.
- Senha temporária original do Access Server: `/usr/local/openvpn_as/init.log`
  dentro do CT (é substituída pela senha que você escolheu).

### Troubleshooting

| Sintoma | Verificação |
|---------|-------------|
| `cannot resolve packages.openvpn.net` | IP/gateway/VLAN/DNS errados; teste com `pct enter <id>` e `ping` |
| CT não sobe após reboot do host (`/dev/net/tun` ausente) | `lsmod \| grep tun` e `cat /etc/modules-load.d/tun.conf` no host |
| VPN conecta mas não passa tráfego | `ls -l /dev/net/tun` dentro do CT; `pct config <id>` deve ter `dev0: /dev/net/tun` |
| Daemons `openvpn_N` em `off` | `sacli ConfigQuery \| grep ovpndco` deve ser `false`; veja `/var/log/openvpnas.log` no CT |
| Admin UI não abre | `pct exec <id> -- /usr/local/openvpn_as/scripts/sacli status` |

## Testes

```bash
bash tests/run.sh   # roda em Docker (debian:trixie), com stubs de pct/pveam/pvesm/pvesh/whiptail
shellcheck openvpn-as-lxc.sh
```

Os testes cobrem validação de entrada, cancelamento, senhas com caracteres
especiais, ausência de template/storage/bridge, rollback em caso de falha e
ausência de senhas nos logs. Eles **não** substituem um teste num nó real.

### Checklist de teste manual num nó Proxmox

1. `bash openvpn-as-lxc.sh --dry-run` e confira os comandos impressos.
2. Execução real com uma VLAN e um IP de teste.
3. `pct config <id>` contém `unprivileged: 1`, `dev0: /dev/net/tun` e `net0` com `tag=`.
4. Login em `https://<IP>:943/admin` com a senha escolhida.
5. Em *Network Settings*, o hostname e as portas batem com o que foi informado.
6. Baixe um perfil na Client UI e conecte via TCP e via UDP.
7. Reinicie o nó e confirme que o CT sobe sozinho (`onboot`) e a VPN volta.
8. Force uma falha (DNS inválido, p.ex. `192.0.2.1`) e confirme a oferta de destruir o CT.
