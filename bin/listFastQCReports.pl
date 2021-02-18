#!/usr/bin/perl -w

$path=$ARGV[0];

%infoPreFilt=();
%infoPostFilt=();

opendir(DIRHANDLE, "$path") || die "Cannot opendir $path: $!";
  foreach $dir (sort readdir(DIRHANDLE)) {
  	opendir(DIRHANDLE2, "$path/$dir") || die "Cannot opendir $path: $!";
    	foreach $name (sort readdir(DIRHANDLE2)) {
    		if($name=~/(.*)_R1_trimmed_fastqc$/){
    			fields("$path/$dir/$name",\%infoPostFilt,$dir);
    		}
    		elsif($name=~/(.*)_R2_trimmed_fastqc$/){
    			fields("$path/$dir/$name",\%infoPostFilt,$dir);
    		}

    		elsif($name=~/(.*)_R1_raw_fastqc$/){
    			fields("$path/$dir/$name",\%infoPreFilt,$dir);
    		}
    		elsif($name=~/(.*)_R2_raw_fastqc$/){
    			fields("$path/$dir/$name",\%infoPreFilt,$dir);
    		}
    	}	
	closedir(DIRHANDLE2);  
}
 

closedir(DIRHANDLE);

@keys=keys(%infoPreFilt);
@keys=sort(@keys);
$len=scalar(@keys);

print "<table class='table'>
		 			<tr>
            <thead>
              <th>Sample</th>";
foreach $key(@keys){
	print "<th>$key</th>";
}

print "</thead><tbody></tr>";
print "<tr><td colspan='",$len+1,"'  class=\"info\">Pre-Filter</td></tr>";
table(\%infoPreFilt,\@keys);
print "</tr><tr><td colspan='",$len+1,"'  class=\"info\">Post-Filter</td></tr>";
table(\%infoPostFilt,\@keys);

print "</tbody></table></div><div><br>";

print "<p>Pre-Filter Reports:</p><ul>";
foreach $key(@keys){	
	print "<li><a target='_blank' href='",$infoPreFilt{$key}{"url"},"'>$key</a></li>";
}
print "</ul>";

print "<p>Post-Filter Reports:</p><ul>";
foreach $key(@keys){	
	print "<li><a target='_blank' href='",$infoPostFilt{$key}{"url"},"'>$key</a></li>";
}
print "</ul>";

exit;

sub table{
	$info=$_[0];
	$keys=$_[1];

	$key = $$keys[0];

	@stats = keys %{$$info{$key}};

	foreach $key2(@stats){
		if($key2=~/[^url]/){
	 		print "<tr>
	 	 		<td>$key2</td>";
	 	 }
	 	foreach $key3(@keys){
	 		if($key2=~/[^url]/){
	 			if($key2=~/^#Total/){
	 				$rounded = sprintf "%.2f", $$info{$key3}{$key2};
	 				print "<td>$rounded</td>";
	 			}else{
	 			print "<td>$$info{$key3}{$key2}</td>";
	 			}
	 		}
	 	}
	 print "</tr>";
	 }
}

sub fields{
	local $dir=$_[0];
	$info=$_[1];
	$sample=$_[2];

	$file="$dir/fastqc_data.txt";

	$$info{$sample}{"url"}="$dir/fastqc_report.html";

	open (IN,$file);
	while(<IN>){
		$line=$_;
		if($line=~/^Total Sequences/ ||
			$line=~/^Sequence length/ ||
			$line=~/^%GC/ ||
			$line=~/^#Total Duplicate Percentage/
		){
		@field=split("\t",$line);
		$$info{$sample}{$field[0]}=$field[1];	
		}
	}
	close IN;
}

