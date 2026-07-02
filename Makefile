# Variables
APP_NAME = worker
DB_NAME  = mysql

.PHONY: up db run down rebuild rebuild-all

# Default action when you just type 'make'
default:
	@echo "Available commands:"
	@echo "  make up          - Start containers"
	@echo "  make db          - Start database container"
	@echo "  make run         - Run worker container"
	@echo "  make down        - Stop containers"
	@echo "  make rebuild     - Rebuild and run worker container"
	@echo "  make rebuild-all - Rebuild all containers"

up:
	docker compose up -d

db:
	docker compose up $(DB_NAME) -d

run:
	docker compose run --rm $(APP_NAME)

bash:
	docker compose run --entrypoint bash $(APP_NAME)

down:
	docker compose down

# Rebuild and restart a specific container (e.g., just rebuild-app)
rebuild:
	docker compose run --rm --build $(APP_NAME)

# Rebuild and restart all containers
rebuild-all:
	docker compose up -d --build
