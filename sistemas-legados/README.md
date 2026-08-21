# Sistemas legados

> Parte fundamental deste repositório, não um apêndice. A maior parte do código que sustenta
> empresas hoje foi escrita há muitos anos — e precisa continuar funcionando enquanto o novo
> é construído.

---

## Documentos

| Documento | Assunto |
|---|---|
| [`modernizacao-incremental-strangler.md`](modernizacao-incremental-strangler.md) | Strangler Fig, Anti-Corruption Layer, introdução de DI e de logging, testes de caracterização, migração de plataforma |
| [`legado-consumindo-api-rest-moderna.md`](legado-consumindo-api-rest-moderna.md) | .NET Framework chamando API moderna: TLS 1.2, `HttpClient`, deadlock, JSON, token |

Conteúdo relacionado espalhado pelo repositório:

| Tema | Onde |
|---|---|
| EF6 | [`../acesso-a-dados/entity-framework-6/ef6-troubleshooting.md`](../acesso-a-dados/entity-framework-6/ef6-troubleshooting.md) |
| SOAP e WCF | [`../api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md`](../api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md) |
| Deadlock de `async` em WebForms/MVC 5 | [`../dotnet/async-await/armadilhas-async-await.md`](../dotnet/async-await/armadilhas-async-await.md) |
| `HttpClient` em .NET Framework | [`../dotnet/httpclient/httpclient-uso-correto.md`](../dotnet/httpclient/httpclient-uso-correto.md) |
| IIS | [`../iis/`](../iis/) |

---

## A premissa deste repositório sobre legado

> **Reescrever tudo não é a solução padrão.**

O sistema antigo contém anos de regra de negócio que existe apenas no código, continua
recebendo demandas durante toda a reescrita, e não entrega valor nenhum até o corte — que
tende a nunca chegar.

A alternativa é substituir por partes, com valor entregue a cada passo e risco pequeno o
suficiente para reverter. É mais lento no papel e muito mais rápido na prática.

---

## Os cinco problemas que aparecem em todo legado .NET

| # | Problema | Onde ler |
|---|---|---|
| 1 | **TLS 1.2** não negociado — integrações param de funcionar sem que nada tenha mudado no código | [`legado-consumindo-api-rest-moderna.md`](legado-consumindo-api-rest-moderna.md) |
| 2 | **Deadlock** por `.Result`/`.Wait()` em ASP.NET clássico | [`../dotnet/async-await/armadilhas-async-await.md`](../dotnet/async-await/armadilhas-async-await.md) |
| 3 | **`HttpClient` em laço** — esgota as portas do servidor | [`../dotnet/httpclient/httpclient-uso-correto.md`](../dotnet/httpclient/httpclient-uso-correto.md) |
| 4 | **`N+1` por lazy loading** — ligado por padrão no EF6 | [`../acesso-a-dados/entity-framework-6/ef6-troubleshooting.md`](../acesso-a-dados/entity-framework-6/ef6-troubleshooting.md) |
| 5 | **Senha de identidade do Application Pool expirada** | [`../iis/troubleshooting/http-503-service-unavailable.md`](../iis/troubleshooting/http-503-service-unavailable.md) |

---

## Por onde começar quando você herda um sistema legado

Ordem de melhor retorno sobre esforço:

**1. Observabilidade.** Sem log e sem `Application Name` na connection string, todo
diagnóstico é adivinhação. Custa pouco e muda tudo.

**2. Corrigir os cinco problemas acima.** São conhecidos, delimitados e de alto impacto.

**3. Testes de caracterização nos caminhos críticos.** Não para validar se a regra está
certa — para impedir que ela mude por acidente.

**4. Extrair a lógica de negócio para bibliotecas .NET Standard 2.0.** Elas rodam tanto no
legado quanto no código novo, e viram a ponte da migração.

**5. Introduzir a fachada (Strangler Fig)** e migrar a primeira funcionalidade.

Se só der para fazer uma coisa, faça a primeira. Um sistema legado observável deixa de ser
uma caixa-preta — e a partir daí toda decisão passa a ter base.

---

**Criado por Fábio Cerqueira**
