FROM oven/bun:1.2.21
WORKDIR /app
COPY d4t_smoke_runner.js /app/d4t_smoke_runner.js
CMD ["bun","/app/d4t_smoke_runner.js"]
