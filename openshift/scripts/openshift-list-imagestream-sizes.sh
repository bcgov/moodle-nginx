
for i in $(oc get istag -o name|cut -d'/' -f2)
do
  echo $i
  oc describe istag $i|grep "Image Size"|cut -d" " -f2
done

echo Done.
# Wait a bit so we can see / copy the results
sleep 100
