#!/bin/bash

YESDNS_PID=0
YESDNS_HTTPS_PID=0

start_yesdns_http() {
  rm -fr db/
  $GOPATH/bin/yesdns -http-listen=localhost:5380 >> yesdns.log 2>&1 &
  YESDNS_PID=$!
  echo YesDNS pid is $YESDNS_PID
  sleep 2
}

start_yesdns_https() {
  rm -fr db/
  openssl genrsa -out server.key 2048
  openssl ecparam -genkey -name secp384r1 -out server.key
  openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650 -subj "/C=US/ST=TX/L=Austin/O=YesDNS/CN=localhost"
  $GOPATH/bin/yesdns -http-listen=localhost:53443 -tls-cert-file=server.crt -tls-key-file=server.key >> yesdns.log 2>&1 &
  YESDNS_HTTPS_PID=$!
  echo YesDNS pid is $YESDNS_HTTPS_PID
  sleep 2
}

kill_yesdns() {
  echo Killing YesDNS with pid $YESDNS_PID
  kill $YESDNS_PID
  kill $YESDNS_HTTPS_PID
}

set_up() {
  set -e
  echo '' > yesdns.log
  # Set up GOPATH
  echo GOPATH is $GOPATH
  # 'go get' requirements
  echo Installing requirements in $GOPATH
  go get github.com/nanobox-io/golang-scribble
  go get github.com/miekg/dns
  # Build YesDNS
  echo Building YesDNS
  go install github.com/alangibson/yesdns
  go install github.com/alangibson/yesdns/cmd/yesdns
  # pre-start the server
  start_yesdns_http
  set +e
}

tear_down() {
  kill_yesdns
}
trap tear_down EXIT

assert_exit_ok() {
  if [ $1 -ne 0 ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! assert_exit_ok failed. Aborting. !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
  else
    echo "----------------------------"
    echo "-- assert_exit_ok passed. --"
    echo "----------------------------"
  fi
}

assert_exit_nok() {
  if [ $1 -eq 0 ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! assert_exit_nok failed. Aborting. !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
  else
    echo "-----------------------------"
    echo "-- assert_exit_nok passed. --"
    echo "-----------------------------"
  fi
}

assert_dig_ok() {
  dig $1 -p $2 $3 $4
  dig +short $1 -p $2 $3 $4 | sed '/^;;/ d' | grep -v -e '^$' > /dev/null
  assert_exit_ok $?
}

assert_dig_nok() {
  dig $1 -p $2 $3 $4
  dig +short $1 -p $2 $3 $4 | sed '/^;;/ d' | grep -v -e '^$' > /dev/null
  assert_exit_nok $?
}

set_up

echo //////////////////////////////////////////////////////////////////////////
echo // Test resolver startup
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/resolver-0.0.0.0:8054.json localhost:5380/v1/resolver
nc -z -v localhost 8054
assert_exit_ok $?

echo //////////////////////////////////////////////////////////////////////////
echo // Test resolver stop
echo //////////////////////////////////////////////////////////////////////////
curl -v -X DELETE -d@./test/data/resolvers/resolver-0.0.0.0:8054.json localhost:5380/v1/resolver
nc -z -v localhost 8054
assert_exit_nok $?

echo //////////////////////////////////////////////////////////////////////////
echo // Test A Record
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/A-default.json localhost:5380/v1/question
assert_dig_ok @localhost 8056 hostname.example.com. A

echo //////////////////////////////////////////////////////////////////////////
echo // Test Authoritative A Record
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/A-default.json localhost:5380/v1/question
dig @localhost -p 8056 hostname.example.com. A | grep 'flags:.*aa.*;'
assert_exit_ok $?

echo //////////////////////////////////////////////////////////////////////////
echo // Test MX Record
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0:8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/MX.json localhost:5380/v1/question
assert_dig_ok @localhost 8056 example.com. MX

echo //////////////////////////////////////////////////////////////////////////
echo // Test SOA Record
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/SOA.json localhost:5380/v1/question
assert_dig_ok @localhost 8056 some.example.com. SOA

echo //////////////////////////////////////////////////////////////////////////
echo // Test Authoritative SOA Record
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/SOA.json localhost:5380/v1/question
dig @localhost -p 8056 some.example.com. SOA | grep 'flags:.*aa.*;'
assert_exit_ok $?

echo //////////////////////////////////////////////////////////////////////////
echo // Test Delete DNS Record
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/A-default.json localhost:5380/v1/question
assert_dig_ok @localhost 8056 hostname.example.com. A
curl -v -X DELETE -d@./test/data/A-default.json localhost:5380/v1/question
assert_dig_nok @localhost 8056 hostname.example.com. A

echo //////////////////////////////////////////////////////////////////////////
echo // Test Wildcard Lookup
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/A-wildcard.json localhost:5380/v1/question
assert_dig_ok @localhost 8056 notreal.example.com. A
# Make sure we correctly echo whatever hostname we were queried with
dig @localhost -p 8056 notreal.example.com. A | grep '^notreal.example.com.'
assert_exit_ok $?

echo //////////////////////////////////////////////////////////////////////////
echo // Test Forwarding
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
assert_dig_ok @localhost 8056 www.google.com. A

echo //////////////////////////////////////////////////////////////////////////
echo // Test Forwarder Delete
echo //////////////////////////////////////////////////////////////////////////
# Add resolver with forwarder
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
assert_dig_ok @localhost 8056 www.google.com. A
# Remove forwarder from previous resolver
jq 'del(.forwarders)' test/data/resolvers/default-0.0.0.0-8056.json | curl -v -X PUT -d@- localhost:5380/v1/resolver
assert_dig_nok @localhost 8056 www.google.com. A

echo //////////////////////////////////////////////////////////////////////////
echo // Test TLS
echo //////////////////////////////////////////////////////////////////////////
start_yesdns_https
yes | openssl s_client -showcerts -connect localhost:53443
assert_exit_ok $?

echo //////////////////////////////////////////////////////////////////////////
echo // Test Forwarding with DNSMasq
echo //////////////////////////////////////////////////////////////////////////
curl -v -X PUT -d@./test/data/resolvers/default-0.0.0.0-8056.json localhost:5380/v1/resolver
curl -v -X PUT -d@./test/data/A-default.json localhost:5380/v1/question
sudo docker rm -f yesdns-dnsmasq
sudo docker run -d --name=yesdns-dnsmasq --net=host --cap-add=NET_ADMIN andyshinn/dnsmasq:2.76 -S '/example.com/127.0.1.1#8056' --log-facility=- --log-queries --port=5399
assert_dig_ok @localhost 5399 hostname.example.com. A
sudo docker logs yesdns-dnsmasq
sudo docker rm -f yesdns-dnsmasq
