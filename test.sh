#!/usr/bin/env bash
# Smoke test: start server, exercise MCP tools + failure scenarios.
set -uo pipefail
PORT=3999
BASE="http://127.0.0.1:$PORT"
ADMIN="-H x-admin-key:admin-key"

PORT=$PORT node src/index.js > /tmp/mock.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1.2

mcp() { # $1=method  $2=params-json
  curl -s -X POST "$BASE/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

scenario() { curl -s -X POST "$BASE/admin/scenario?scenario=$1" $ADMIN; }

echo "=== 1. tools/list ==="
mcp "tools/list" '{}' | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  const r=JSON.parse(d);
  (r.result?.tools||[]).forEach(t=>console.log(' -',t.name));
  if(!r.result) console.log(JSON.stringify(r));
});"

echo
echo "=== 2. happy path: pincode -> create -> track ==="
mcp "tools/call" '{"name":"delhivery_check_pincode","arguments":{"pin":"560102"}}' \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d);const t=r.result?.content?.[0]?.text||JSON.stringify(r);console.log('serviceable:', JSON.parse(t).delivery_codes.length>0);});"

WB=$(mcp "tools/call" '{"name":"delhivery_create_shipment","arguments":{"order_id":"DIN-001","pin":"560102","address":"12 HSR Layout","name":"Priya","phone":"9800000000","payment_mode":"Prepaid","pickup_location":"HSR Store","total_amount":60}}' \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const t=JSON.parse(d).result.content[0].text;console.log(JSON.parse(t).packages[0].waybill);});")
echo "waybill: $WB"

mcp "tools/call" "{\"name\":\"delhivery_track_shipment\",\"arguments\":{\"waybill\":\"$WB\"}}" \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const t=JSON.parse(d).result.content[0].text;const s=JSON.parse(t).ShipmentData[0].Shipment;console.log('status:',s.Status.Status,'| delivered:',s.DeliveryDate);});"

echo
echo "=== 3. failure scenarios ==="
for S in pin_not_serviceable no_rider late_delivery malformed server_error auth_fail; do
  scenario "$S" > /dev/null
  case $S in
    pin_not_serviceable)
      OUT=$(mcp "tools/call" '{"name":"delhivery_check_pincode","arguments":{"pin":"560102"}}') ;;
    auth_fail|server_error|malformed)
      OUT=$(mcp "tools/call" '{"name":"delhivery_check_pincode","arguments":{"pin":"560102"}}') ;;
    *)
      OUT=$(mcp "tools/call" "{\"name\":\"delhivery_track_shipment\",\"arguments\":{\"waybill\":\"$WB\"}}") ;;
  esac
  echo "$OUT" | node -e "
let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{
  const r=JSON.parse(d);
  const t=(r.result?.content?.[0]?.text)||'';
  const err=r.result?.isError?'ERROR ':'ok    ';
  console.log('  $S'.padEnd(26), err, t.replace(/\s+/g,' ').slice(0,90));
});"
done

echo
echo "=== 4. create with bad body shape (docs require format=json&data=) ==="
scenario happy > /dev/null
curl -s -X POST "$BASE/mcp" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"delhivery_create_shipment","arguments":{"order_id":"X","pin":"560102","address":"a","name":"n","phone":"9","payment_mode":"Prepaid","pickup_location":"","total_amount":1}}}' \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const r=JSON.parse(d);console.log('  isError:',!!r.result?.isError,'|',(r.result?.content?.[0]?.text||'').replace(/\s+/g,' ').slice(0,100));});"

echo
echo "=== 5. audit log count ==="
curl -s "$BASE/admin/calls" $ADMIN | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log('  calls logged:',JSON.parse(d).count));"
