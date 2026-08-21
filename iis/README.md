# IIS

> Onde aplicações .NET morrem em silêncio. O IIS raramente é a causa — mas é onde o sintoma
> aparece, e onde estão os registros que explicam o que aconteceu.

---

## Documentos

| Documento | Assunto |
|---|---|
| [`troubleshooting/http-503-service-unavailable.md`](troubleshooting/http-503-service-unavailable.md) | Application Pool parado, Rapid-Fail Protection, senha de identidade expirada, fila cheia |
| [`troubleshooting/http-500-e-http-502.md`](troubleshooting/http-500-e-http-502.md) | Tabela de subcódigos, `web.config` inválido, aplicação que não sobe, memory leak |

---

## O primeiro reflexo certo

**Anote o código completo, com o subcódigo.** `500` sozinho não diz nada; `500.19` e
`500.30` são problemas de naturezas opostas — um é configuração do IIS, outro é falha de
inicialização da aplicação.

---

## Onde tudo está registrado

| O quê | Onde |
|---|---|
| Estado dos Application Pools | `Get-ChildItem IIS:\AppPools` |
| Por que o pool parou | Visualizador de Eventos → **Sistema** → origem **WAS** |
| Exceção que derrubou a aplicação | Visualizador de Eventos → **Aplicativo** |
| Requisições presas **agora** | `appcmd list requests /elapsed:5000` |
| Histórico de requisições | `%SystemDrive%\inetpub\logs\LogFiles` |
| Detalhe módulo a módulo | Failed Request Tracing (FREB) |
| Saída da aplicação ASP.NET Core | `stdoutLogFile` do `web.config` |

O comando mais subestimado:

```powershell
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list requests /elapsed:5000
```

Ele lista as requisições em execução há mais de cinco segundos, com URL, tempo e o módulo
em que estão — dizendo, em uma linha, se a aplicação está travada no banco, em uma chamada
externa ou em processamento próprio.

---

## Quando o IIS não é o problema

A maioria dos incidentes que aparecem como erro de IIS tem causa em outro lugar:

| Sintoma no IIS | Causa real provável |
|---|---|
| 503 com fila cheia | Threads bloqueadas por `.Result`/`.Wait()` — [`../dotnet/async-await/armadilhas-async-await.md`](../dotnet/async-await/armadilhas-async-await.md) |
| 500 intermitente sob carga | Pool de conexão esgotado — [`../acesso-a-dados/ado-net/connection-pool-esgotado.md`](../acesso-a-dados/ado-net/connection-pool-esgotado.md) |
| Timeout em toda a aplicação | Bloqueio no banco — [`../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql`](../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) |
| Memória crescendo até reciclar | `HttpClient` em laço — [`../dotnet/httpclient/httpclient-uso-correto.md`](../dotnet/httpclient/httpclient-uso-correto.md) |
| Falha ao chamar serviço externo | TLS antigo em .NET Framework — [`../api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md`](../api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md) |

---

## Higiene de servidor que evita incidente

- [ ] Identidade do pool com **gMSA** ou `ApplicationPoolIdentity` — sem senha para expirar.
- [ ] Um Application Pool por aplicação (evita `500.34`/`500.35` e isola falhas).
- [ ] Reciclagem em horário fixo, fora do pico.
- [ ] Alerta nos eventos WAS 5002, 5009, 5021 e 5117.
- [ ] Logs do IIS com retenção e limpeza automática — eles enchem disco.
- [ ] `stdoutLogEnabled` e `customErrors mode="Off"` **desligados** em produção.
- [ ] Antivírus com exclusão para as pastas da aplicação e dos logs.
- [ ] .NET Hosting Bundle atualizado nos servidores ASP.NET Core.

---

**Criado por Fábio Cerqueira**
