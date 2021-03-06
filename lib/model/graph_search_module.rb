# encoding: utf-8

# Copyright © 2014-2017 Lennart Bierkandt <post@lennartbierkandt.de>
#
# This file is part of GraphAnno.
#
# GraphAnno is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# GraphAnno is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GraphAnno. If not, see <http://www.gnu.org/licenses/>.

require 'unicode_utils/downcase.rb'
require 'csv.rb'

module GraphSearch
	include Parser

	def teilgraph_suchen(query)
		operations = parse_query(query)

		puts 'Searching for graph fragment ...'
		startzeit = Time.new

		nodes_to_be_searched = []
		edges_to_be_searched = []
		tglisten = {}
		id_index = {}
		tgindex = 0

		# Vorgehen:
		# Anfrage auf Wohlgeformtheit prüfen
		# edge in link umwandeln, wenn :start und :end gegeben
		# meta: zu durchsuchenden Graph einschränken
		# edge ohne :start und :end suchen
		# node/nodes: passende Knoten jeweils als TG
		# text: Textfragmente
		# edge/link: node/nodes-TGn und text-TGn kombinieren

		# check validity of query
		unless (error_messages = query_errors(operations)).empty?
			raise error_messages * "\n"
		end

		# edge in link umwandeln, wenn Start und Ziel gegeben
		convert_edge_clauses(operations)

		# meta
		# hier wird ggf. der zu durchsuchende Graph eingeschränkt
		if metabedingung = operation_erzeugen(:op => 'and', :arg => operations['meta'].map{|op| op[:cond]})
			nodes_to_be_searched = sentence_nodes.select{|s| s.fulfil?(metabedingung, true)}.map{|s| s.nodes}.flatten
			edges_to_be_searched = nodes_to_be_searched.map{|n| n.in + n.out}.flatten.uniq
		else
			nodes_to_be_searched = @node_index['t'].values + @node_index['a'].values
			edges_to_be_searched = @edges.values
		end

		# edge
		operations['edge'].each do |operation|
			gefundene_kanten = edges_to_be_searched.select{|k| k.fulfil?(operation[:cond])}
			tglisten[tgindex += 1] = gefundene_kanten.map do |k|
				Teilgraph.new([], [k], {operation[:id] => [k]})
			end
			id_index[operation[:id]] = {:index => tgindex, :art => operation[:operator], :cond => operation[:cond]}
		end

		# node/nodes
		# gefundene Knoten werden als atomare Teilgraphen gesammelt
		(operations['node'] + operations['nodes']).each do |operation|
			gefundene_knoten = nodes_to_be_searched.select{|k| k.fulfil?(operation[:cond])}
			tglisten[tgindex += 1] = gefundene_knoten.map do |k|
				Teilgraph.new([k], [], {operation[:id] => [k]})
			end
			if operation[:operator] == 'nodes'
				tglisten[tgindex] << Teilgraph.new([], [], {operation[:id] => []})
			end
			id_index[operation[:id]] = {:index => tgindex, :art => operation[:operator], :cond => operation[:cond]}
		end

		# text
		# ein oder mehrer Teilgraphenlisten werden erstellt
		operations['text'].each do |operation|
			tglisten[tgindex += 1] = textsuche_NFA(nodes_to_be_searched.of_type('t'), operation[:arg], operation[:id])
			# id_index führen
			if operation[:id]
				id_index[operation[:id]] = {:index => tgindex, :art => operation[:operator]}
			end
			operation[:ids].each do |id|
				id_index[id] = {:index => tgindex, :art => operation[:operator]}
			end
		end

		# link
		# atomare Teilgraphen werden zu Ketten verbunden
		operations['link'].sort{|a,b| link_operation_vergleichen(a, b, id_index)}.each_with_index do |operation, operation_index|
			startid = operation[:start]
			zielid = operation[:end]
			next unless id_index[startid] && id_index[zielid]
			startindex = id_index[startid][:index]
			zielindex = id_index[zielid][:index]
			tgl_start = tglisten[startindex]
			tgl_ziel = tglisten[zielindex]
			schon_gesucht = {}
			neue_tgl = []

			automat = Automat.create(operation[:arg])
			automat.bereinigen
			#automat.zustaende.each{|z| puts z; puts z.typ; puts z.uebergang; puts z.folgezustand; puts}

			if id_index[startid][:art] != 'text'
				if id_index[zielid][:art] != 'text'
					# erstmal node(s) -> node(s)
					tgl_start.each do |starttg|
						startknot = starttg.ids[startid][0]
						unless breitensuche = schon_gesucht[startknot]
							if startknot
								breitensuche = startknot.links(automat, id_index[zielid][:cond])
							else
								breitensuche = []
							end
							breitensuche = [[nil, Teilgraph.new]] if breitensuche == []
							schon_gesucht[startknot] = breitensuche
						end
						breitensuche.each do |zielknot, pfadtg|
							if startindex != zielindex # wenn Start und Ziel in verschiedenen TGLn
								zieltgn = tgl_ziel.select{|tg| tg.ids[zielid][0] == zielknot}
								zieltgn.each do |zieltg|
									neue_tgl << starttg + pfadtg + zieltg
								end
							else # wenn Start und Ziel in selber TGL
								if starttg.ids[zielid][0] == zielknot
									neue_tgl << starttg + pfadtg
								end
							end
						end
					end
				else # wenn Ziel 'text' ist
					tgl_start.each do |starttg|
						startknot = starttg.ids[startid][0]
						unless breitensuche = schon_gesucht[startknot]
							if startknot
								breitensuche = startknot.links(automat, {:operator => 'token'}) # Zielknoten muß Token sein
							else
								breitensuche = []
							end
							schon_gesucht[startknot] = breitensuche
						end
						if startindex != zielindex # wenn Start und Ziel in verschiedenen TGLn
							zieltgn = tgl_ziel.select{|tg| tg.ids[zielid] - breitensuche.map{|knot, pfad| knot} == []}
							zieltgn.each do |zieltg|
								pfadtg = breitensuche.select{|knot, pfad| zieltg.ids[zielid].include?(knot)}.map{|knot, pfad| pfad}.reduce(:+)
								neue_tgl << starttg + pfadtg + zieltg
							end
						else # wenn Start und Ziel in selber TGL
							if starttg.ids[zielid] - breitensuche.map{|knot, pfad| knot} == []
								pfadtg = breitensuche.select{|knot, pfad| zieltg.ids[zielid].include?(knot)}.map{|knot, pfad| pfad}.reduce(:+)
								neue_tgl << starttg + pfadtg
							end
						end
					end
				end
			else # wenn Start 'text' ist
			end

			# alte tg-Listen löschen
			tglisten.delete(startindex)
			tglisten.delete(zielindex)
			# neue einfügen
			tglisten[tgindex += 1] = neue_tgl
			# link-ids in id_index
			operation[:ids].each do |id|
				id_index[id] = {:index => tgindex, :art => operation[:operator]}
			end
			# id_index auffrischen
			id_index.each do |id,tgi|
				id_index[id][:index] = tgindex if tgi[:index] == startindex || tgi[:index] == zielindex
			end
			# Operation löschen
			operations['link'].delete_at(operation_index)
		end

		# Teilgraphen zusammenfassen, und zwar dann, wenn sie alle ihre "node"-Knoten bzw. "text"e teilen
		if operations['nodes'] != []
			node_indizes = id_index.select{|s,w| w[:art] == 'node' || w[:art] == 'text'}
			# für jede TG-Liste, die "node"s oder "text"e enthält:
			node_indizes.values.map{|h| h[:index]}.uniq.each do |node_tgindex|
				node_ids = node_indizes.select{|s,w| w[:index] == node_tgindex}.keys
				zusammengefasste_tg = {}
				tglisten[node_tgindex].each do |referenztg|
					# "node"s/"text"e des Referenz-TG
					uebereinstimmend = referenztg.ids.select{|s,w| node_ids.include?(s)}.values.map{|k| k.sort_by{|n| n.id.to_i}}
					# in Hash unter "uebereinstimmend"en Knoten zusammenfassen
					if zusammengefasste_tg[uebereinstimmend]
						zusammengefasste_tg[uebereinstimmend] += referenztg
					else
						zusammengefasste_tg[uebereinstimmend] = referenztg
					end
				end
				# alte tg-Liste löschen
				tglisten.delete(node_tgindex)
				# neue einfügen
				tglisten[tgindex += 1] = zusammengefasste_tg.values
				# id_index auffrischen
				id_index.each do |id,tgi|
					id_index[id] = tgindex if tgi == node_tgindex
				end
			end
		end

		tgliste = tglisten.values.flatten(1)
		tgliste.each{|tg| tg.set_ids(id_index)}

		# cond
		operations['cond'].each do |op|
			begin
				tgliste.select!{|tg| tg.execute(op[:string])}
			rescue NoMethodError => e
				match = e.message.match(/undefined method `(\w+)' for .+:(\w+)/)
				raise "Undefined method '#{match[1]}' for #{match[2]} in line:\ncond #{op[:string]}"
			rescue StandardError => e
				raise "#{e.message} in line:\ncond #{op[:string]}"
			rescue SyntaxError => e
				raise clean_syntax_error_message(:message => e.message, :line => "cond #{op[:string]}")
			end
		end

		puts "Found #{tgliste.length.to_s} matches in #{(Time.new - startzeit).to_s} seconds"
		puts

		return tgliste
	end

	def query_errors(operations)
		text_ids = operations['text'].map{|o| ([o[:id]] + o[:ids]).flatten.compact}
		node_ids = operations['node'].map{|o| o[:id]}
		nodes_ids = operations['nodes'].map{|o| o[:id]}
		edge_start_end_ids = operations['edge'].map{|o| [o[:start], o[:end]]}
		link_start_end_ids = operations['link'].map{|o| [o[:start], o[:end]]}
		edge_ids = operations['edge'].map{|o| o[:id]}
		link_ids = operations['link'].map{|o| o[:ids]}.flatten
		anno_ids = @@annotation_commands.map{|c| operations[c].map{|o| o[:ids]}}.flatten.uniq
		# at least one node, edge or text clause
		if operations['node'] + operations['edge'].select{|o| !(o[:start] or o[:end])} + operations['text'] == []
			return ['A query must contain at least one node clause, edge clause or text clause.']
		end
		# check for multiply defined ids
		error_messages = []
		all_ids = (text_ids + node_ids + nodes_ids + edge_ids + link_ids).flatten.compact
		all_ids.select{|id| all_ids.count(id) > 1}.uniq.each do |id|
			error_messages << "The id #{id} is multiply defined."
		end
		# references to undefined ids?
		erlaubte_start_end_ids = node_ids + nodes_ids + text_ids.flatten
		benutzte_start_end_ids = (edge_start_end_ids + link_start_end_ids).flatten.compact
		als_referenz_erlaubte_ids = erlaubte_start_end_ids + edge_ids + link_ids
		benutzte_start_end_ids.each do |id|
			error_messages << "The id #{id} is used as start or end, but is not defined." unless erlaubte_start_end_ids.include?(id)
		end
		['cond', 'sort', 'col'].each do |op_type|
			operations[op_type].map{|o| o[:ids]}.flatten.each do |id|
				unless als_referenz_erlaubte_ids.include?(id)
					error_messages << "The id #{id} is used in #{op_type} clause, but is not defined."
				end
			end
		end
		if (undefined_ids = anno_ids - als_referenz_erlaubte_ids) != []
			if undefined_ids.length == 1
				error_messages << "The id #{undefined_ids[0]} is used in annotation command, but is not defined."
			else
				error_messages << "The ids #{undefined_ids * ', '} are used in annotation command, but are not defined."
			end
		end
		# check for dangling edges
		if erlaubte_start_end_ids.length > 0 and operations['edge'].any?{|o| !(o[:start] && o[:end])} or
			erlaubte_start_end_ids.length == 0 and operations['edge'].length > 1
			error_messages << 'There are dangling edges.'
		end
		# coherent graph fragment?
		groups = text_ids + (node_ids + nodes_ids).map{|id| [id]}
		links = edge_start_end_ids + link_start_end_ids
		unless groups.groups_linked?(links)
			error_messages << 'The defined graph fragment is not coherent.'
		end
		return error_messages
	end

	def convert_edge_clauses(operations)
		operations['edge'].clone.each do |operation|
			if operation[:start] and operation[:end]
				operations['link'] << {
					:operator => 'edge',
					:start => operation[:start],
					:end   => operation[:end],
					:arg   => operation.reject{|s,w| [:start, :end].include?(s)},
					:ids   => [operation[:id]].compact
				}
				operations['edge'].delete(operation)
			end
		end
	end

	def textsuche_NFA(tokens_to_be_searched, operation, id = nil)
		automat = Automat.create(operation)
		automat.bereinigen

		# Grenzknoten einbauen (das muß natürlich bei einem Graph mit verbundenen Sätzen und mehreren Ebenen anders aussehen)
		grenzknoten = []
		tokens_to_be_searched.each do |tok|
			unless tok.node_before
				grenzknoten << add_token_node(:attr => {'cat' => 'boundary', 'level' => 's'}, :raw => true)
				add_order_edge(:start => grenzknoten.last, :end => tok)
			end
			unless tok.node_after
				grenzknoten << add_token_node(:attr => {'cat' => 'boundary', 'level' => 's'}, :raw => true)
				add_order_edge(:start => tok, :end => grenzknoten.last)
			end
		end

		ergebnis = []
		(tokens_to_be_searched + grenzknoten).each do |node|
			if t = automat.text_suchen_ab(node)
				t.remove_boundary_nodes!
				ergebnis << t
			end
		end
		if id
			ergebnis.each do |tg|
				tg.ids[id] = tg.nodes.clone
			end
		end

		# Grenzknoten wieder entfernen
		grenzknoten.each do |node|
			node.delete
		end

		return ergebnis
	end

	def link_operation_vergleichen(a, b, id_index)
		# sortiert so, daß zuerst node-node-Verbindungen kommen, dann node-anderes oder anderes-node und dann anderes-anderes
		wert_a = ([id_index[a[:start]][:art], id_index[a[:end]][:art]] - ['node']).length
		wert_b = ([id_index[b[:start]][:art], id_index[b[:end]][:art]] - ['node']).length
		return wert_a - wert_b
	end

	def operation_erzeugen(p)
		case p[:op]
		when 'and', 'or'
			if p[:arg].length == 2
				return {:operator => p[:op], :arg => p[:arg]}
			elsif p[:arg].length < 2
				return p[:arg][0]
			else
				return {:operator => p[:op], :arg => [p[:arg][0], operationen_verknuepfen(:op => p[:op], :arg => p[:arg][1..-1])]}
			end
		when 'not' # wenn mehr als ein Argument: not(arg1 or arg2 or ...)
			if p[:arg].length == 1
				return {:operator => p[:op], :arg => p[:arg][0]}
			elsif p[:arg].length == 0
				return nil
			else
				return {:operator => p[:op], :arg => [operationen_verknuepfen(:op => 'or', :arg => p[:arg])]}
			end
		end
	end

	def teilgraph_ausgeben(found, befehle, datei = :console)
		operations = parse_query(befehle)

		# Sortieren
		found.tg.each do |tg|
			tg.ids.values.each{|arr| arr.sort_by!{|n| n.id.to_i}}
		end
		found.tg.sort! do |a,b|
			# Hierarchie der sort-Befehle abarbeiten
			vergleich = 0
			operations['sort'].reject{|op| !op}.each do |op|
				begin
					vergleich = a.execute(op[:string]) <=> b.execute(op[:string])
				rescue NoMethodError => e
					match = e.message.match(/undefined method `(\w+)' for .+:(\w+)/)
					raise "Undefined method '#{match[1]}' for #{match[2]} in line:\nsort #{op[:string]}"
				rescue StandardError => e
					raise "#{e.message} in line:\nsort #{op[:string]}"
				rescue SyntaxError => e
					raise clean_syntax_error_message(:message => e.message, :line => "sort #{op[:string]}")
				end
				break vergleich if vergleich != 0
			end
			vergleich
		end

		# Ausgabe
		if datei.is_a?(String) or datei == :string
			rueck = CSV.generate(:col_sep => "\t") do |csv|
				csv << ['match_no'] + operations['col'].map{|o| o[:title]}
				found.tg.each_with_index do |tg, i|
					csv << [i+1] + operations['col'].map do |op|
						begin
							tg.execute(op[:string])
						rescue NoMethodError => e
							match = e.message.match(/undefined method `(\w+)' for .+:(\w+)/)
							raise "Undefined method '#{match[1]}' for #{match[2]} in line:\ncol #{op[:title]} #{op[:string]}"
						rescue StandardError => e
							raise "#{e.message} in line:\ncol #{op[:title]} #{op[:string]}"
						rescue SyntaxError => e
							raise clean_syntax_error_message(:message => e.message, :line => "col #{op[:title]} #{op[:string]}")
						end
					end
				end
			end
			if datei.is_a?(String)
				puts 'Writing output to file "' + datei + '.csv".'
				open(datei + '.csv', 'wb') do |file|
					file.write(rueck)
				end
			elsif datei == :string
				return rueck
			end
		elsif datei == :console
			found.tg.each_with_index do |tg, i|
				puts "match #{i}"
				operations['col'].each do |op|
					begin
						puts "#{op[:title]}: #{tg.execute(op[:string])}"
					rescue StandardError => e
						raise "#{e.message} in line:\ncol #{op[:title]} #{op[:string]}"
					end
				end
				puts
			end
		end
	end

	def teilgraph_annotieren(found, command_string, log_step = nil)
		search_result_preserved = true
		commands = parse_query(command_string)[:all].select{|c| @@annotation_commands.include?(c[:operator])}
		found.tg.each do |tg|
			layer = nil
			commands.each do |command|
				# set attributes (same for all commands except 'a')
				annotations = interpolate(command[:annotations], tg)
				# set layer (same for all commands)
				if layer_shortcut = command[:words].select{|l| conf.layer_by_shortcut.keys.include?(l)}.last
					layer = conf.layer_by_shortcut[layer_shortcut]
				end
				# extract elements
				elements = command[:ids].map{|id| tg.ids[id]}.flatten.uniq.compact
				nodes = elements.select{|e| e.is_a?(Node)}
				# process the commands
				case command[:operator]
				when 'a'
					elements.each do |el|
						el.annotate(annotations, log_step)
					end
				when 'n'
					if ref_node = nodes.first
						add_anno_node(
							:anno => annotations,
							:layers => layer,
							:sentence => ref_node.sentence,
							:log => log_step
						)
					end
				when 'e'
					start_nodes = *tg.ids[command[:ids][0]]
					end_nodes   = *tg.ids[command[:ids][1]]
					start_nodes.select!{|e| e.is_a?(Node)}
					end_nodes.select!{|e| e.is_a?(Node)}
					start_nodes.product(end_nodes).each do |start_node, end_node|
						add_anno_edge(
							:start => start_node,
							:end => end_node,
							:anno => annotations,
							:layers => layer,
							:log => log_step
						)
					end
				when 'p', 'g'
					unless nodes.empty?
						add_parent_node(
							nodes,
							:node_anno => annotations,
							:sentence => command[:words].include?('i') ? nil : nodes.first.sentence,
							:layers => layer,
							:log => log_step
						)
					end
				when 'c', 'h'
					unless nodes.empty?
						add_child_node(
							nodes,
							:node_anno => annotations,
							:sentence => command[:words].include?('i') ? nil : nodes.first.sentence,
							:layers => layer,
							:log => log_step
						)
					end
				when 'd'
					elements.each do |el|
						el.delete(:join => true, :log => log_step) if el
						search_result_preserved = false
					end
				when 'ni'
					elements.select{|e| e.is_a?(Edge)}.each do |e|
						insert_node(
							e,
							:anno => annotations,
							:sentence => command[:words].include?('i') ? nil : e.end.sentence,
							:layers => layer,
							:log => log_step
						)
						search_result_preserved = false
					end
				when 'di', 'do'
					nodes.each do |n|
						delete_and_join(n, command[:operator] == 'di' ? :in : :out, log_step)
						search_result_preserved = false
					end
				when 'tb', 'ti'
					build_tokens(command[:words][1..-1], :next_token => nodes.of_type('t').first, :log => log_step)
				when 'ta'
					build_tokens(command[:words][1..-1], :last_token => nodes.of_type('t').last, :log => log_step)
				when 'l'
					elements.each{|el| el.set_layer(layer, log_step)} if layer
				end
			end #command
		end # tg
		return search_result_preserved
	end

	def interpolate(annotations, tg)
		annotations.map do |annotation|
			begin
				annotation[:value] = tg.execute("\"#{annotation[:value]}\"") if annotation[:value]
				annotation
			rescue NoMethodError => e
				match = e.message.match(/undefined method `(\w+)' for .+:(\w+)/)
				raise "Undefined method '#{match[1]}' for #{match[2]} in string:\n\"#{annotation[:value]}\""
			rescue StandardError => e
				raise "#{e.message} in string:\n\"#{annotation[:value]}\""
			rescue SyntaxError => e
				raise clean_syntax_error_message(:message => e.message)
			end
		end
	end

	def clean_syntax_error_message(h)
		if h[:line]
			h[:message].sub(/^\(eval\):1: (.+)\n.+\n.*\^.*$/, "\\1 in line:\n#{h[:line]}")
		else
			h[:message].sub(/^\(eval\):1: (.+)\n(.+)\n.*\^.*$/, "\\1 in string:\n\\2")
		end
	end
end
