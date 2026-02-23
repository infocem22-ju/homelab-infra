#!/bin/bash

# Vérifiez l'état du Docker Compose
ETAT=$(docker-compose ps | grep -c "Up")

if [ $ETAT -eq 0 ]; then
  # Lancez les conteneurs si ils ne sont pas en cours d'exécution
  echo "Lancement des conteneurs..."
  docker-compose up -d
else
  # Confirmez avant de stopper les conteneurs
  read -p "Arrêter les conteneurs ? (o/n) : " REPONSE

  if [ "$REPONSE" = "o" ]; then
    echo "Arrêt des conteneurs..."
    docker-compose down
  else
    echo "Lancement annulé."
  fi
fi
