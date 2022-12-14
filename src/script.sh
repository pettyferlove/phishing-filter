#!/bin/sh

set -efux -o pipefail

## Detect Musl C library
LIBC="$(ldd /bin/ls | grep 'musl' || [ $? = 1 ])"
if [ -z "$LIBC" ]; then
  rm -f "/tmp/musl.log"
  # Not Musl
  CSVQUOTE="../utils/csvquote-bin-glibc"
else
  # Musl
  CSVQUOTE="../utils/csvquote-bin-musl"
fi


## Create a temporary working folder
mkdir -p "tmp/"
cd "tmp/"

## Prepare datasets
curl -L "https://data.phishtank.com/data/$PHISHTANK_API/online-valid.csv.bz2" -o "phishtank.bz2"
curl -L "https://openphish.com/feed.txt" -o "openphish-raw.txt"
curl -L "https://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip" -o "top-1m-umbrella.zip"
curl -L "https://tranco-list.eu/top-1m.csv.zip" -o "top-1m-tranco.zip"
curl -L "https://oisd.nl/excludes.php" -o "oisd-exclude.html"

bunzip2 -kc "phishtank.bz2" > "phishtank.csv"


## Parse URLs
cat "phishtank.csv" | \
tr "[:upper:]" "[:lower:]" | \
## Workaround for column with double quotes
"./$CSVQUOTE" | \
cut -f 2 -d "," | \
"./$CSVQUOTE" -u | \
sed 's/"//g' | \
cut -f 3- -d "/" | \
# Domain must have at least a 'dot'
grep -F "." | \
sed "s/^www\.//g" | \
# url encode space #11
sed "s/ /%20/g" > "phishtank.txt"

cat "openphish-raw.txt" | \
dos2unix | \
tr "[:upper:]" "[:lower:]" | \
cut -f 3- -d "/" | \
grep -F "." | \
sed "s/^www\.//g" | \
sed "s/ /%20/g" > "openphish.txt"

## Combine PhishTank and OpenPhish
cat "phishtank.txt" "openphish.txt" | \
sort -u > "phishing.txt"

## Parse domain and IP address only
cat "phishing.txt" | \
cut -f 1 -d "/" | \
cut -f 1 -d ":" | \
# #2
cut -f 1 -d "?" | \
sort -u > "phishing-domains.txt"


cp "../src/exclude.txt" "."

## Parse the Umbrella 1 Million
unzip -p "top-1m-umbrella.zip" | \
dos2unix | \
tr "[:upper:]" "[:lower:]" | \
# Parse domains only
cut -f 2 -d "," | \
grep -F "." | \
# Remove www.
sed "s/^www\.//g" | \
sort -u > "top-1m-umbrella.txt"

## Parse the Tranco 1 Million
unzip -p "top-1m-tranco.zip" | \
dos2unix | \
tr "[:upper:]" "[:lower:]" | \
# Parse domains only
cut -f 2 -d "," | \
grep -F "." | \
# Remove www.
sed "s/^www\.//g" | \
sort -u > "top-1m-tranco.txt"

## Parse oisd exclusion list
cat "oisd-exclude.html" | \
# https://stackoverflow.com/a/47600828
xmlstarlet format --recover --html 2>/dev/null | \
xmlstarlet select --html --template --value-of '//a' | \
## Append new line https://unix.stackexchange.com/a/31955
sed '$a\' > "oisd-exclude.txt"

# Merge Umbrella, Traco and self-maintained top domains
cat "top-1m-umbrella.txt" "top-1m-tranco.txt" "exclude.txt" "oisd-exclude.txt" | \
sort -u > "top-1m-well-known.txt"


## Parse popular domains
cat "phishing-domains.txt" | \
# grep match whole line
grep -Fx -f "top-1m-well-known.txt" > "phishing-top-domains.txt"


## Exclude popular domains
cat "phishing-domains.txt" | \
grep -F -vf "phishing-top-domains.txt" > "phishing-notop-domains-temp.txt"

cat "phishing.txt" | \
grep -F -f "phishing-top-domains.txt" > "phishing-url-top-domains-temp.txt"

rm -f "phishing-url-top-domains.txt" "phishing-url-top-domains-raw.txt"

## Temporarily disable command print
set +x

while read URL; do
  HOST=$(echo "$URL" | cut -d"/" -f1)
  URI=$(echo "$URL" | sed "s/^$HOST//")

  ## Separate host-only URL
  if [ -z "$URI" ] || [ "$URI" = "/" ]; then
    echo "$HOST" | \
    cut -f 1 -d ":" >> "phishing-notop-domains-temp.txt"
  else
    ## Parse phishing URLs from popular domains
    echo "$URL" | \
    sed -e "s/^/||/g" -e "s/$/\$all/g" >> "phishing-url-top-domains.txt"
    echo "$URL" >> "phishing-url-top-domains-raw.txt"
  fi
done < "phishing-url-top-domains-temp.txt"

## Re-enable command print
set -x

## "phishing-url-top-domains-temp.txt" may add duplicate entries
sort -u "phishing-notop-domains-temp.txt" > "phishing-notop-domains.txt"


## Merge malware domains and URLs
CURRENT_TIME="$(date -R -u)"
FIRST_LINE="! Title: Phishing URL Blocklist"
SECOND_LINE="! Updated: $CURRENT_TIME"
THIRD_LINE="! Expires: 1 day (update frequency)"
FOURTH_LINE="! Homepage: https://gitlab.com/curben/phishing-filter"
FIFTH_LINE="! License: https://gitlab.com/curben/phishing-filter#license"
SIXTH_LINE="! Source: https://www.phishtank.com/ & https://openphish.com/"
NOTICE="\n! Notice: https://curben.gitlab.io/phishing-filter-mirror is moved to https://curben.gitlab.io/malware-filter\n"
COMMENT_UBO="$FIRST_LINE\n$SECOND_LINE\n$THIRD_LINE\n$FOURTH_LINE\n$FIFTH_LINE\n$SIXTH_LINE\n$NOTICE"


cat "phishing-notop-domains.txt" "phishing-url-top-domains.txt" | \
sort | \
sed '1 i\'"$COMMENT_UBO"'' > "../dist/phishing-filter.txt"


# Adguard Home
cat "phishing-notop-domains.txt" | \
sed "s/^/||/g" | \
sed "s/$/^/g" > "phishing-domains-adguard-home.txt"

cat "phishing-domains-adguard-home.txt" | \
sort | \
sed '1 i\'"$COMMENT_UBO"'' | \
sed "1s/Blocklist/Blocklist (AdGuard Home)/" > "../dist/phishing-filter-agh.txt"


# Adguard browser extension
cat "phishing-notop-domains.txt" | \
sed "s/^/||/g" | \
sed "s/$/\$all/g" > "phishing-domains-adguard.txt"

cat "phishing-domains-adguard.txt" "phishing-url-top-domains.txt" | \
sort | \
sed '1 i\'"$COMMENT_UBO"'' | \
sed "1s/Blocklist/Blocklist (AdGuard)/" > "../dist/phishing-filter-ag.txt"


# Vivaldi
cat "phishing-notop-domains.txt" | \
sed "s/^/||/g" | \
sed "s/$/\$document/g" > "phishing-domains-vivaldi.txt"

cat "phishing-domains-vivaldi.txt" "phishing-url-top-domains.txt" | \
sed "s/\$all$/\$document/g" | \
sort | \
sed '1 i\'"$COMMENT_UBO"'' | \
sed "1s/Blocklist/Blocklist (Vivaldi)/" > "../dist/phishing-filter-vivaldi.txt"


## Domains-only blocklist
# awk + head is a workaround for sed prepend
COMMENT=$(printf "$COMMENT_UBO" | sed "s/^!/#/g" | sed "1s/URL/Domains/" | awk '{printf "%s\\n", $0}' | head -c -2)

cat "phishing-notop-domains.txt" | \
sort | \
sed '1 i\'"$COMMENT"'' > "../dist/phishing-filter-domains.txt"

cat "phishing-notop-domains.txt" | \
grep -vE "^([0-9]{1,3}[\.]){3}[0-9]{1,3}$" > "phishing-notop-hosts.txt"

## Hosts file blocklist
cat "phishing-notop-hosts.txt" | \
sed "s/^/0.0.0.0 /g" | \
# Re-insert comment
sed '1 i\'"$COMMENT"'' | \
sed "1s/Domains/Hosts/" > "../dist/phishing-filter-hosts.txt"


## Dnsmasq-compatible blocklist
cat "phishing-notop-hosts.txt" | \
sed "s/^/address=\//g" | \
sed "s/$/\/0.0.0.0/g" | \
sed '1 i\'"$COMMENT"'' | \
sed "1s/Blocklist/dnsmasq Blocklist/" > "../dist/phishing-filter-dnsmasq.conf"


## BIND-compatible blocklist
cat "phishing-notop-hosts.txt" | \
sed 's/^/zone "/g' | \
sed 's/$/" { type master; notify no; file "null.zone.file"; };/g' | \
sed '1 i\'"$COMMENT"'' | \
sed "1s/Blocklist/BIND Blocklist/" > "../dist/phishing-filter-bind.conf"


## DNS Response Policy Zone (RPZ)
CURRENT_UNIX_TIME="$(date +%s)"
RPZ_SYNTAX="\n\$TTL 30\n@ IN SOA rpz.curben.gitlab.io. hostmaster.rpz.curben.gitlab.io. $CURRENT_UNIX_TIME 86400 3600 604800 30\n NS localhost.\n"

cat "phishing-notop-hosts.txt" | \
sed "s/$/ CNAME ./g" | \
sed '1 i\'"$RPZ_SYNTAX"'' | \
sed '1 i\'"$COMMENT"'' | \
sed "s/^#/;/g" | \
sed "1s/Blocklist/RPZ Blocklist/" > "../dist/phishing-filter-rpz.conf"


## Unbound-compatible blocklist
cat "phishing-notop-hosts.txt" | \
sed 's/^/local-zone: "/g' | \
sed 's/$/" always_nxdomain/g' | \
sed '1 i\'"$COMMENT"'' | \
sed "1s/Blocklist/Unbound Blocklist/" > "../dist/phishing-filter-unbound.conf"


## dnscrypt-proxy blocklists
# name-based
cat "phishing-notop-hosts.txt" | \
sed '1 i\'"$COMMENT"'' | \
sed "1s/Domains/Names/" > "../dist/phishing-filter-dnscrypt-blocked-names.txt"

# IPv4-based
cat "phishing-notop-domains.txt" | \
sort | \
grep -E "^([0-9]{1,3}[\.]){3}[0-9]{1,3}$" | \
sed '1 i\'"$COMMENT"'' | \
sed "1s/Domains/IPs/" > "../dist/phishing-filter-dnscrypt-blocked-ips.txt"


set +x

## Snort & Suricata rulesets
rm -f "../dist/phishing-filter-snort2.rules" \
  "../dist/phishing-filter-snort3.rules" \
  "../dist/phishing-filter-suricata.rules"

SID="200000001"
while read DOMAIN; do
  SN_RULE="alert tcp \$HOME_NET any -> \$EXTERNAL_NET [80,443] (msg:\"phishing-filter phishing website detected\"; flow:established,from_client; content:\"GET\"; http_method; content:\"$DOMAIN\"; content:\"Host\"; http_header; classtype:attempted-recon; sid:$SID; rev:1;)"

  SN3_RULE="alert http \$HOME_NET any -> \$EXTERNAL_NET any (msg:\"phishing-filter phishing website detected\"; http_header:field host; content:\"$DOMAIN\",nocase; classtype:attempted-recon; sid:$SID; rev:1;)"

  SR_RULE="alert http \$HOME_NET any -> \$EXTERNAL_NET any (msg:\"phishing-filter phishing website detected\"; flow:established,from_client; http.method; content:\"GET\"; http.host; content:\"$DOMAIN\"; classtype:attempted-recon; sid:$SID; rev:1;)"

  echo "$SN_RULE" >> "../dist/phishing-filter-snort2.rules"
  echo "$SN3_RULE" >> "../dist/phishing-filter-snort3.rules"
  echo "$SR_RULE" >> "../dist/phishing-filter-suricata.rules"

  SID=$(( $SID + 1 ))
done < "phishing-notop-domains.txt"

while read URL; do
  HOST=$(echo "$URL" | cut -d"/" -f1)
  URI=$(echo "$URL" | sed -e "s/^$HOST//" -e "s/;/\\\;/g")

  # Snort2 only supports <=2047 characters of `content`
  SN_RULE="alert tcp \$HOME_NET any -> \$EXTERNAL_NET [80,443] (msg:\"phishing-filter phishing website detected\"; flow:established,from_client; content:\"GET\"; http_method; content:\"$(echo $URI | cut -c -2047)\"; http_uri; nocase; content:\"$HOST\"; content:\"Host\"; http_header; classtype:attempted-recon; sid:$SID; rev:1;)"

  SN3_RULE="alert http \$HOME_NET any -> \$EXTERNAL_NET any (msg:\"phishing-filter phishing website detected\"; http_header:field host; content:\"$HOST\",nocase; http_uri; content:\"$URI\",nocase; classtype:attempted-recon; sid:$SID; rev:1;)"

  SR_RULE="alert http \$HOME_NET any -> \$EXTERNAL_NET any (msg:\"phishing-filter phishing website detected\"; flow:established,from_client; http.method; content:\"GET\"; http.uri; content:\"$URI\"; endswith; nocase; http.host; content:\"$HOST\"; classtype:attempted-recon; sid:$SID; rev:1;)"

  echo "$SN_RULE" >> "../dist/phishing-filter-snort2.rules"
  echo "$SN3_RULE" >> "../dist/phishing-filter-snort3.rules"
  echo "$SR_RULE" >> "../dist/phishing-filter-suricata.rules"

  SID=$(( $SID + 1 ))
done < "phishing-url-top-domains-raw.txt"

set -x

sed -i '1 i\'"$COMMENT"'' "../dist/phishing-filter-snort2.rules"
sed -i "1s/Domains Blocklist/URL Snort2 Ruleset/" "../dist/phishing-filter-snort2.rules"

sed -i '1 i\'"$COMMENT"'' "../dist/phishing-filter-snort3.rules"
sed -i "1s/Domains Blocklist/URL Snort3 Ruleset/" "../dist/phishing-filter-snort3.rules"

sed -i '1 i\'"$COMMENT"'' "../dist/phishing-filter-suricata.rules"
sed -i "1s/Domains Blocklist/URL Suricata Ruleset/" "../dist/phishing-filter-suricata.rules"


## IE blocklist
COMMENT_IE="msFilterList\n$COMMENT\n: Expires=1\n#"

cat "phishing-notop-hosts.txt" | \
sed "s/^/-d /g" | \
sed '1 i\'"$COMMENT_IE"'' | \
sed "2s/Domains Blocklist/Hosts Blocklist (IE)/" > "../dist/phishing-filter.tpl"


## Clean up artifacts
rm "phishtank.csv" "top-1m-umbrella.zip" "top-1m-umbrella.txt" "top-1m-tranco.txt" "openphish-raw.txt" "oisd-exclude.html" "oisd-exclude.txt"


cd ../
