# QuickStack

Docker Swarm Stacks is a collection of pre-configured stack files designed to simplify the deployment of various services in a Docker Swarm cluster.

---

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [Stacks Available](#stacks-available)
- [Contributing](#contributing)
- [License](#license)

---

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/felipefontoura/quickstack.git
   cd quickstack
   ```

2. Ensure Docker Swarm is initialized:

   ```bash
   docker swarm init
   ```

---

## Usage

1. Navigate to project path:

   ```bash
   cd quickstack
   ```

2. Adjust stack file:

   ```bash
   nano stacks/<category>/<stack>.yml
   ```

2. Run the docker

   ```bash
   docker stack deploy --prune --resolve-image always --compose-file ./<category>/<stack>.yml stack
   ```

3. Monitor your services:

   ```bash
   docker service ls
   ```

---

## Stacks Available

### Infrastructure

- **[Traefik](stacks/infra/traefik.yml):** Application proxy and load balancer.
- **[Portainer](stacks/infra/portainer.yml):** Platform manager for Docker and Swarm.

### Databases

- **[PostgreSQL](stacks/db/postgres.yml):** Relational database with advanced features.
- **[Redis](stacks/db/redis.yml):** In-memory key-value store for caching and real-time analytics.

### Applications

- **[Chatwoot](stacks/app/chatwoot.yml):** The modern customer support tool for your business.
- **[Evolution API](stacks/app/evolution-api.yml):** API framework for evolutionary development.
- **[N8n](stacks/app/n8n.yml):** Workflow automation tool.
- **[Plunk](stacks/app/plunk.yml):** The Open-Source email platform.
- **[RabbitMQ](stacks/app/rabbitmq.yml):** Message broker for distributed systems, ideal for asynchronous communication and message queuing.
- **[Typebot](stacks/app/typebot.yml):** Chatbot builder for interactive conversations.

---

## Contributing

Contributions are welcome! If you want to contribute:

1. Fork the repository.
2. Add or update a stack.
3. Submit a pull request.

For major changes, please open an issue first to discuss the proposal.

---

## License

This repository is licensed under the [MIT License](https://choosealicense.com/licenses/mit/). Use, modify, and distribute freely!
