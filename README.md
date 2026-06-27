# TASKR - Production-Grade On-Demand Labor Marketplace

A complete, production-ready microservices platform for connecting customers with on-demand service providers in India.

## 🎯 Features

- **Microservices Architecture**: 9 independent services for scalability
- **Real-time Tracking**: Socket.io for live GPS tracking and notifications
- **Intelligent Matching**: Advanced algorithm for worker-task matching
- **Integrated Payments**: Razorpay integration with PCI compliance
- **Multi-platform**: Flutter mobile app + Node.js backend
- **Highly Scalable**: Kubernetes-ready, handles 10M+ users
- **Production Monitoring**: Prometheus, Grafana, ELK stack integration

## 🏗️ Architecture

### Services
- **Auth Service** (3001): JWT, OAuth, Aadhaar verification
- **Task Service** (3002): Task CRUD, search, filtering
- **Worker Service** (3003): Profile, availability, location
- **Matching Service** (3004): Intelligent matching algorithm
- **Payment Service** (3005): Razorpay integration, escrow, payouts
- **Notification Service** (3006): Push, SMS, email notifications
- **Analytics Service** (3007): Events, funnels, dashboards
- **Location Service** (3008): Maps, geocoding, ETA
- **WebSocket Server** (3009): Real-time tracking and messaging

### Data Layer
- **PostgreSQL**: Primary relational database
- **Redis**: Caching, sessions, real-time data
- **MongoDB**: Analytics and event logs
- **Elasticsearch**: Task search and discovery
- **RabbitMQ**: Async task processing

## 📋 Prerequisites

- Node.js 18+
- Docker & Docker Compose
- PostgreSQL 14+
- Redis 7+
- Flutter 3.10+ (for mobile app)
- kubectl (for Kubernetes deployment)

## 🚀 Quick Start

### Local Development

```bash
# Clone the repository
git clone <repo-url>
cd Taskr

# Copy environment variables
cp .env.example .env

# Start all services with Docker Compose
docker-compose up -d

# Run database migrations
npm run migrate

# Seed sample data
npm run seed

# Start backend services
npm start

# Start Flutter app (in flutter_app directory)
cd flutter_app
flutter pub get
flutter run
```

### Services Running

- Auth Service: http://localhost:3001
- Task Service: http://localhost:3002
- Worker Service: http://localhost:3003
- Matching Service: http://localhost:3004
- Payment Service: http://localhost:3005
- Notification Service: http://localhost:3006
- Analytics Service: http://localhost:3007
- Location Service: http://localhost:3008
- WebSocket: ws://localhost:3009
- Admin API: http://localhost:3010

### Monitoring

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000
- Kibana: http://localhost:5601

## 📦 Project Structure

```
Taskr/
├── services/              # Microservices
│   ├── auth-service/
│   ├── task-service/
│   ├── worker-service/
│   ├── matching-service/
│   ├── payment-service/
│   ├── notification-service/
│   ├── analytics-service/
│   ├── location-service/
│   └── websocket-server/
├── shared/               # Shared utilities
│   ├── database/
│   ├── utils/
│   ├── constants/
│   └── types/
├── flutter_app/          # Mobile application
├── kubernetes/           # K8s manifests
├── infrastructure/       # Terraform IaC
├── monitoring/           # Prometheus, Grafana configs
├── tests/               # E2E, load, integration tests
├── docs/                # Documentation
└── scripts/             # Setup and deployment scripts
```

## 🔧 Configuration

Edit `.env` file to customize:
- Database credentials
- API keys (Razorpay, Firebase, Twilio)
- JWT secrets
- Allowed origins
- Service ports

## 🧪 Testing

```bash
# Run all tests
npm test

# Run specific service tests
npm --workspace=services/task-service test

# Load testing
npm run load-test

# E2E tests
npm run test:e2e
```

## 📊 Monitoring & Observability

Services expose Prometheus metrics at `/metrics` endpoint. Grafana dashboards are available for:
- System metrics (CPU, memory, network)
- Business KPIs (task completion, worker earnings)
- Error rates and latency

## 🔐 Security

- JWT-based authentication
- Role-based access control (RBAC)
- HTTPS/TLS encryption
- Rate limiting
- SQL injection prevention
- CORS configuration
- Data encryption at rest

See [SECURITY.md](docs/SECURITY.md) for detailed security implementation.

## 📈 Scaling

For production deployment:
1. Configure AWS RDS for PostgreSQL
2. Set up ElastiCache for Redis
3. Deploy to EKS using provided Kubernetes manifests
4. Configure auto-scaling policies
5. Set up monitoring and alerting

See [SCALING.md](docs/SCALING.md) for detailed scaling strategies.

## 📚 Documentation

- [API Documentation](docs/API.md)
- [Architecture Guide](docs/ARCHITECTURE.md)
- [Deployment Guide](docs/DEPLOYMENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## 🤝 Contributing

1. Create feature branch: `git checkout -b feature/your-feature`
2. Commit changes: `git commit -am 'Add feature'`
3. Push to branch: `git push origin feature/your-feature`
4. Open Pull Request

## 📄 License

Proprietary - All rights reserved

## 📞 Support

For issues and questions, please open an issue in the repository or contact the development team.

---

**Built with ❤️ for the Indian gig economy**
