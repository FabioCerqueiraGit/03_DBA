# ASP.NET — das WebForms ao ASP.NET Core

> Esta área reconhece que quase ninguém trabalha em uma versão só. O sistema que fatura está no
> .NET Framework; o novo está no .NET 10; e os dois precisam conversar.

---

## Conteúdo

| Documento | Resolve |
|---|---|
| [Mapa de versões e equivalências](mapa-de-versoes-e-equivalencias.md) | "Como eu faço isso no Core, se no MVC 5 era assim?" — tabela de tradução para configuração, contexto, DI, roteamento, HTTP, log, sessão e assíncrono. Inclui o que **não** tem equivalente |
| [Ordem do pipeline de middleware](aspnet-core/ordem-do-pipeline-de-middleware.md) | `[Authorize]` que não autoriza, CORS que não libera, arquivo protegido que qualquer um baixa |

---

## A regra desta área

> **Nunca apresente uma solução moderna como se fosse compatível com o legado.**

Quando houver diferença relevante entre plataformas, o conteúdo deste repositório apresenta os
três estágios:

**Legado** (funciona hoje, no .NET Framework) **→ Intermediário** (melhora sem trocar de
plataforma) **→ Moderno** (ASP.NET Core).

O estágio intermediário é o mais útil e o mais ignorado. Ele entrega valor imediato — código
testável, dependência explícita, log estruturado — sem depender de um projeto de migração que pode
nunca ser aprovado. E, quando a migração vier, ela será menor.

---

## As três armadilhas que mais custam caro

**1. `HttpContext.Current` em profundidade.**
No ASP.NET Core ele não existe. Sistemas legados costumam depender dele dentro de repositórios e
helpers — e essa dependência só aparece em tempo de execução, durante a migração. Trabalho útil
hoje: passar o que é realmente necessário (usuário, tenant, correlation ID) como parâmetro.

**2. `.Result` e `.Wait()` em MVC 5 / Web API 2.**
Com `SynchronizationContext` presente, isso causa **deadlock** — a requisição trava até o timeout,
sem exceção e sem log. O mesmo código, copiado de um exemplo de ASP.NET Core, funciona lá e trava
aqui. Ver [`dotnet/async-await/`](../dotnet/async-await/).

**3. Ordem do pipeline no ASP.NET Core.**
`UseAuthorization()` antes de `UseAuthentication()` não gera erro: gera endpoint desprotegido.
Falha de segurança silenciosa é a pior categoria de defeito.

---

## Migração: o caminho que costuma dar certo

Não é "parar tudo e reescrever". É colocar uma aplicação ASP.NET Core na frente com proxy reverso
(YARP) e mover uma rota por vez, com os **System.Web adapters** permitindo que as bibliotecas
compartilhadas compilem nos dois mundos durante a transição.

O detalhamento está no [mapa de versões](mapa-de-versoes-e-equivalencias.md#o-caminho-incremental),
e o padrão arquitetural por trás dele (Strangler Fig, Anti-Corruption Layer) está em
[`sistemas-legados/`](../sistemas-legados/).

**Antes de começar, duas perguntas honestas:**

1. Existe teste automatizado nos fluxos críticos? Se não, escrever testes de caracterização vem
   primeiro. Migração sem rede de segurança é aposta.
2. A migração resolve o problema que realmente incomoda hoje? Se a queixa é lentidão, o gargalo
   costuma estar no banco — comece por
   [`sql-server/troubleshooting/`](../sql-server/troubleshooting/).

---

## Navegação relacionada

- Sistemas legados e modernização incremental: [`sistemas-legados/`](../sistemas-legados/)
- Armadilhas de `async`/`await` e deadlock: [`dotnet/async-await/`](../dotnet/async-await/)
- Erros de IIS que parecem erro de aplicação: [`iis/troubleshooting/`](../iis/troubleshooting/)
- Consumo de API a partir de sistema legado: [`api-integracao/`](../api-integracao/)
- Autenticação e autorização em API: [`api-integracao/autenticacao/`](../api-integracao/autenticacao/)

---

**Criado por Fábio Cerqueira**
