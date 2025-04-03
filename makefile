mumble:
	docker compose up -d

run:
	@if [ -z "$$(docker compose ps -q mumble)" ]; then \
		echo "💀 You fucking idiot, you forgot to start the mumble server locally. Run 'make mumble' first dipshit."; \
		exit 1; \
	else \
		echo "🔥 You fucking idiot, we have to write Elixir first before we can run it."; \
	fi

down:
	docker compose down
